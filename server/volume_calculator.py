import numpy as np
import os
import json
import logging
import trimesh
from scipy.spatial.transform import Rotation
from util.io import load_and_align_scene, load_jsonl, get_image_center_ray
from util.geometry import (
    compute_ray_intersection, detect_plane_below_point, fit_circle_ransac,
    detect_circle_at_axis, get_slice
)
from util.transforms import transform_point_from_arcore, transform_point_to_arcore
from util.constants import (
    PLANE_SEARCH_BELOW, PLANE_THICKNESS, PLANE_MIN_POINTS,
    AXIS_SEARCH_RANGE, AXIS_SEARCH_STEP, THICKNESS, MIN_POINTS_PER_SLICE,
    MAX_CONSECUTIVE_FAILURES,
    WEIGHT_PPM_AXIS, WEIGHT_INLIER_RATIO_AXIS, WEIGHT_ANGLE_COVERAGE_AXIS,
    WEIGHT_GRID_COVERAGE_AXIS, WEIGHT_RAY_DISTANCE_AXIS
)

logger = logging.getLogger("VolumeCalculator")

def calculate_volume(session_path):
    """
    Main entry point for volume calculation.
    """
    glb_path = os.path.join(session_path, "output", "scene.glb")
    jsonl_path = os.path.join(session_path, "metadata.jsonl")

    if not os.path.exists(glb_path):
        raise FileNotFoundError(f"GLB file not found at {glb_path}")
    if not os.path.exists(jsonl_path):
        raise FileNotFoundError(f"JSONL metadata not found at {jsonl_path}")

    # 1. Load Data
    data = load_jsonl(jsonl_path)
    data.sort(key=lambda x: x.get('timestamp' , x.get('t_ns', 0)))
    
    # 2. Ray Intersection (Anchor Correction)
    # Note: Using Seol's logic for anchor correction, even if anchors aren't used.
    # If no anchors, it defaults to identity.
    
    first_frame = data[0]
    camera_positions = []
    ray_origins = []
    ray_directions = []
    
    for item in data:
        # Use raw pose directly without anchor correction
        pos_gl = np.array(item['pos'])
        quat_gl = item['quat']
        
        fx = item.get('fx', item.get('intrinsics', {}).get('fx', 0))
        fy = item.get('fy', item.get('intrinsics', {}).get('fy', 0))
        cx = item.get('cx', item.get('intrinsics', {}).get('cx', 0))
        cy = item.get('cy', item.get('intrinsics', {}).get('cy', 0))
        
        origin, direction = get_image_center_ray(pos_gl, quat_gl, fx, fy, cx, cy)
        ray_origins.append(origin)
        ray_directions.append(direction)

    ray_intersection, avg_error, _, _ = compute_ray_intersection(ray_origins, ray_directions)
    logger.info(f"Ray intersection: {ray_intersection}, error: {avg_error*1000:.2f}mm")

    # 3. Load and Align Point Cloud
    points, scene_metadata, align_transform = load_and_align_scene(glb_path)
    if points is None:
        raise ValueError("Failed to load point cloud from GLB")

    # [Added] Downsampling to speed up processing
    TARGET_POINTS = 200000 
    if len(points) > TARGET_POINTS:
        idx = np.random.choice(len(points), TARGET_POINTS, replace=False)
        points = points[idx]
        logger.info(f"Downsampled point cloud to {TARGET_POINTS} points for faster processing")

    # 4. Transform intersection to scene coordinates
    ray_intersection_scene = transform_point_from_arcore(ray_intersection, first_frame, scene_metadata)

    # 5. Plane Detection & Filtering
    plane_z, _ = detect_plane_below_point(
        points, 
        ray_intersection_scene[2],
        search_below=PLANE_SEARCH_BELOW,
        thickness=PLANE_THICKNESS,
        min_points=PLANE_MIN_POINTS
    )
    if plane_z is not None:
        points = points[points[:, 2] > plane_z]
    
    sorted_idx = np.argsort(points[:, 2])
    sorted_points, sorted_heights = points[sorted_idx], points[sorted_idx, 2]

    # 6. Axis Search
    ray_z = ray_intersection_scene[2]
    z_min_search = max(ray_z - AXIS_SEARCH_RANGE, sorted_heights.min())
    z_max_search = min(ray_z + AXIS_SEARCH_RANGE, sorted_heights.max())
    z_range = np.arange(z_min_search, z_max_search + AXIS_SEARCH_STEP, AXIS_SEARCH_STEP)
    
    circle_data = []
    ray_intersection_2d = ray_intersection_scene[:2]
    
    for z in z_range:
        start = np.searchsorted(sorted_heights, z - THICKNESS)
        end = np.searchsorted(sorted_heights, z + THICKNESS)
        if end - start < MIN_POINTS_PER_SLICE:
            continue
        
        slice_2d = sorted_points[start:end, :2]
        circle = fit_circle_ransac(slice_2d, n_iter=50, threshold=0.005, min_inliers=10, ray_intersection_2d=ray_intersection_2d)
        if circle:
            circle_data.append({'z': z, **circle})

    if not circle_data:
        return 0.0, "Couldn't detect cup axis", None, None, None

    # Score and Pick Best Axis
    all_ppms = [c['ppm'] for c in circle_data]
    ppm_min, ppm_max = min(all_ppms), max(all_ppms)
    
    for c in circle_data:
        ppm_norm = (c['ppm'] - ppm_min) / (ppm_max - ppm_min + 1e-8)
        # Fixed weights for final ranking (Step 2): PPM 0.3, Inlier Ratio 0.7
        c['ranking_score'] = (
            (ppm_norm + 1e-8) ** 0.3 *
            (c['score'] + 1e-8) ** 0.7
        )
    
    # Sort by the Step 2 specific ranking score
    circle_data.sort(key=lambda x: x['ranking_score'], reverse=True)
    best = circle_data[0]
    center_axis = best['center']
    max_radius_limit = best['radius'] * 1.15
    
    # 7. Volume Calculation via Slicing
    filter_mask = np.sum((sorted_points[:, :2] - center_axis)**2, axis=1) < 0.15**2
    filtered_points = sorted_points[filter_mask]
    
    volume_data = []
    STEP = 0.002
    
    def add_vol(z, r):
        volume_data.append({'z': z, 'area': np.pi * r**2})

    # Central scan
    ref_slice = get_slice(filtered_points, best['z'])
    ref_r = detect_circle_at_axis(ref_slice[:, :2], center_axis, max_radius=max_radius_limit)
    if ref_r:
        add_vol(best['z'], ref_r)
        
        # Upward (Stops on FIRST failure)
        curr_z = best['z'] + STEP
        while curr_z < filtered_points[:, 2].max():
            sl = get_slice(filtered_points, curr_z)
            r = detect_circle_at_axis(sl[:, :2], center_axis, max_radius=max_radius_limit)
            if not r: 
                break
            add_vol(curr_z, r)
            curr_z += STEP
            
        # Downward (Allows up to 3 consecutive failures)
        curr_z = best['z'] - STEP
        consecutive_failures = 0
        while curr_z > filtered_points[:, 2].min():
            sl = get_slice(filtered_points, curr_z)
            r = detect_circle_at_axis(sl[:, :2], center_axis, max_radius=max_radius_limit)
            if r:
                consecutive_failures = 0
                add_vol(curr_z, r)
            else:
                consecutive_failures += 1
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    break
            curr_z -= STEP

    if not volume_data:
        return 0.0, "Couldn't detect volume slices", None, None, None

    volume_data.sort(key=lambda x: x['z'])
    
    # --- [Added] Top-down Outlier Correction for Bottom ---
    # Prevents volume inflation caused by floor noise near the cup bottom.
    if len(volume_data) > 5:
        bottom_z = volume_data[0]['z']
        start_idx = 0
        # Find index 3cm above the bottom
        for i, v_item in enumerate(volume_data):
            if v_item['z'] > bottom_z + 0.03:
                start_idx = i
                break
        
        # Check downwards from start_idx to the bottom
        for i in range(start_idx, -1, -1):
            if i + 1 >= len(volume_data): continue
            # If radius grows by more than 1.5x (area by 2.25x) compared to the slice above
            if volume_data[i]['area'] > volume_data[i+1]['area'] * (1.5**2):
                logger.info(f"Correcting bottom outlier at z={volume_data[i]['z']:.4f}")
                volume_data[i]['area'] = volume_data[i+1]['area']
    # ------------------------------------------------------

    
    # Calculate volume profile (cumulative volume at each height)
    volume_profile = []
    cumulative_m3 = 0.0
    for i in range(len(volume_data) - 1):
        dv = (volume_data[i]['area'] + volume_data[i+1]['area']) / 2 * (volume_data[i+1]['z'] - volume_data[i]['z'])
        cumulative_m3 += dv
        volume_profile.append({
            'z': volume_data[i+1]['z'],
            'cumulative_ml': cumulative_m3 * 1e6,
            'radius': np.sqrt(volume_data[i+1]['area'] / np.pi)  # For ring drawing
        })
    
    total_vol_m3 = cumulative_m3
    volume_ml = total_vol_m3 * 1e6 # cm3 (mL)
    
    # --- Save Debug Data (JSON) ---
    debug_data = {
        "status": "Success",
        "total_volume_ml": round(volume_ml, 2),
        "volume_profile": volume_profile,
        "metadata": {
            "center_axis": center_axis.tolist() if center_axis is not None else None,
            "max_radius_limit": float(max_radius_limit),
            "n_slices": len(volume_data),
            "alignment_matrix": align_transform.T.tolist() if align_transform is not None else None
        }
    }
    debug_path = os.path.join(session_path, "volume_debug.json")
    try:
        with open(debug_path, 'w') as f:
            json.dump(debug_data, f, indent=4)
        logger.info(f"Saved volume debug data to {debug_path}")
    except Exception as e:
        logger.error(f"Failed to save debug data: {e}")
    # ------------------------------
    
    # Calculate cup bottom center in ARKit coordinates
    bottom_z = volume_data[0]['z']
    cup_bottom_scene = np.array([center_axis[0], center_axis[1], bottom_z])
    
    try:
        cup_bottom_arkit = transform_point_to_arcore(cup_bottom_scene, first_frame, scene_metadata)
        logger.info(f"Cup bottom center (ARKit): {cup_bottom_arkit}")
    except Exception as e:
        logger.warning(f"Failed to transform cup bottom center: {e}")
        cup_bottom_arkit = None
    
    # Store metadata needed for height calculation
    calc_metadata = {
        'center_axis': center_axis.tolist(),
        'first_frame': first_frame,
        'scene_metadata': scene_metadata,
        'volume_profile': volume_profile
    }
    
    return volume_ml, "Success", cup_bottom_arkit, volume_profile, calc_metadata


def find_height_for_volume(volume_profile, target_ml, center_axis, first_frame, scene_metadata):
    """
    Find the Z height and radius for a target volume using linear interpolation.
    Returns (height_arkit, radius) or (None, None) if target exceeds max volume.
    """
    if not volume_profile or target_ml <= 0:
        return None, None
    
    # Find the two points that bracket the target volume
    prev = {'z': volume_profile[0]['z'], 'cumulative_ml': 0, 'radius': volume_profile[0]['radius']}
    
    for curr in volume_profile:
        if curr['cumulative_ml'] >= target_ml:
            # Linear interpolation
            if curr['cumulative_ml'] == prev['cumulative_ml']:
                t = 0
            else:
                t = (target_ml - prev['cumulative_ml']) / (curr['cumulative_ml'] - prev['cumulative_ml'])
            
            z = prev['z'] + t * (curr['z'] - prev['z'])
            radius = prev['radius'] + t * (curr['radius'] - prev['radius'])
            
            # Transform to ARKit coordinates
            point_scene = np.array([center_axis[0], center_axis[1], z])
            try:
                point_arkit = transform_point_to_arcore(point_scene, first_frame, scene_metadata)
                return point_arkit.tolist(), float(radius)
            except Exception as e:
                logger.warning(f"Failed to transform fill height: {e}")
                return None, None
        prev = curr
    
    # Target exceeds max volume
    return None, None
