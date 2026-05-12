import os
# Fix for Mac OpenMP conflict and MPS unsupported operators
# os.environ["KMP_DUPLICATE_LIB_OK"] = "TRUE"
# os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

import numpy as np
import json
from scipy.spatial.transform import Rotation
from depth_anything_3.api import DepthAnything3
from PIL import Image
import glob
import os
import re
import logging

logger = logging.getLogger("DA3Module")

_MODEL = None

def get_da3_model():
    """Singleton-like function to load and return the DA3 model."""
    global _MODEL
    if _MODEL is None:
        import torch
        device = "cuda" if torch.cuda.is_available() else "cpu"
        logger.info(f"Pre-loading DA3 model on {device}...")
        try:
            _MODEL = DepthAnything3.from_pretrained("depth-anything/da3-base").to(device)
            logger.info("DA3 model loaded successfully.")
        except Exception as e:
            logger.error(f"Failed to load DA3 model: {e}")
            raise
    return _MODEL

def load_jsonl(jsonl_path):
    data = []
    if not os.path.exists(jsonl_path):
        return data
    with open(jsonl_path, 'r') as f:
        for line in f:
            if line.strip():
                try:
                    data.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return data

def run_da3_reconstruction(session_path, output_dir=None):
    """
    Runs DA3 reconstruction on a session folder.
    Expects metadata.jsonl and frame_*.jpg (or img_*.jpg) files.
    """
    if output_dir is None:
        output_dir = os.path.join(session_path, "output")
    os.makedirs(output_dir, exist_ok=True)

    jsonl_file = os.path.join(session_path, "metadata.jsonl")
    image_files = sorted(glob.glob(os.path.join(session_path, "img_*.jpg")))
    
    # If no img_*.jpg, try frame_*.jpg
    if not image_files:
        image_files = sorted(glob.glob(os.path.join(session_path, "frame_*.jpg")))

    if not os.path.exists(jsonl_file):
        raise FileNotFoundError(f"JSONL metadata not found at {jsonl_file}")
    
    jsonl_data = load_jsonl(jsonl_file)
    if not jsonl_data:
        raise ValueError("JSONL data is empty")

    # Match images with metadata based on timestamp
    # In namho2, we use img_{timestamp}.jpg and same timestamp in jsonl
    matched_data = []
    
    # Create image map by timestamp string
    image_map = {}
    for img_path in image_files:
        # Extract timestamp from img_TIMESTAMP.jpg
        name = os.path.basename(img_path)
        # Handle both img_TIMESTAMP.jpg and frame_N.jpg (for compatibility)
        ts_match = re.search(r'img_([\d\.]+)\.jpg', name)
        if ts_match:
            image_map[ts_match.group(1)] = img_path
        else:
            frame_match = re.search(r'frame_(\d+)\.jpg', name)
            if frame_match:
                image_map[frame_match.group(1)] = img_path

    for item in jsonl_data:
        ts = str(item.get('timestamp'))
        if ts in image_map:
            matched_data.append({
                'image': image_map[ts],
                'params': item
            })
    
    if not matched_data:
        # Fallback: simple index matching if timestamp doesn't match perfectly
        logger.warning("Timestamp matching failed, falling back to index matching")
        for i, item in enumerate(jsonl_data):
            if i < len(image_files):
                matched_data.append({
                    'image': image_files[i],
                    'params': item
                })

    N = len(matched_data)
    if N == 0:
        raise ValueError("No matched data for reconstruction")

    extrinsics = np.zeros((N, 4, 4), dtype=np.float32)
    intrinsics = np.zeros((N, 3, 3), dtype=np.float32)
    matched_image_files = []

    # Coordinate transformation
    # ARKit/ARCore (Right Handed, Y Up) -> COLMAP/CV (Right Handed, Y Down)
    gl_to_cv = np.array([
        [1,  0,  0],
        [0, -1,  0],
        [0,  0, -1]
    ], dtype=np.float32)

    for i, item in enumerate(matched_data):
        params = item['params']
        img_path = item['image']
        
        # Extrinsics
        quat = params.get('quat') # [x, y, z, w]
        pos = params.get('pos')   # [x, y, z]
        
        if quat is None or pos is None:
            continue
            
        R_c2w_gl = Rotation.from_quat(quat).as_matrix()
        R_c2w_cv = gl_to_cv @ R_c2w_gl @ gl_to_cv.T
        pos_cv = gl_to_cv @ pos
        
        c2w = np.eye(4, dtype=np.float32)
        c2w[:3, :3] = R_c2w_cv
        c2w[:3, 3] = pos_cv
        w2c = np.linalg.inv(c2w)
        
        extrinsics[i] = w2c
        matched_image_files.append(img_path)
        
        # Intrinsics
        fx = params.get('fx', params.get('intrinsics', {}).get('fx'))
        fy = params.get('fy', params.get('intrinsics', {}).get('fy'))
        cx = params.get('cx', params.get('intrinsics', {}).get('cx'))
        cy = params.get('cy', params.get('intrinsics', {}).get('cy'))
        
        # COLMAP uses 0-based center
        cx_colmap = cx - 0.5 if cx is not None else 0
        cy_colmap = cy - 0.5 if cy is not None else 0
        
        intrinsics[i] = np.array([
            [fx or 0, 0.0, cx_colmap],
            [0.0, fy or 0, cy_colmap],
            [0.0, 0.0, 1.0]
        ], dtype=np.float32)

    # Use Pre-loaded Model
    logger.info(f"Starting DA3 inference for {N} frames...")
    try:
        model = get_da3_model()
        
        prediction = model.inference(
            image=matched_image_files,
            extrinsics=extrinsics,
            intrinsics=intrinsics,
            align_to_input_ext_scale=True,
            use_ray_pose=True,
            export_dir=output_dir,
            export_format="glb",
            process_res=840,
        )
        
        output_glb = os.path.join(output_dir, "scene.glb")
        logger.info(f"Reconstruction completed: {output_glb}")
        return output_glb
    except Exception as e:
        logger.error(f"DA3 Inference failed: {e}")
        raise
