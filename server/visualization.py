import trimesh
import sys
import os
import numpy as np
from scipy.spatial.transform import Rotation

def load_and_show_scene(glb_path):
    """
    Load a GLB file and visualize it using trimesh.
    Includes logic to align the scene with gravity if metadata is present.
    """
    if not os.path.exists(glb_path):
        print(f"Error: File not found at {glb_path}")
        return

    try:
        # Load the scene
        scene = trimesh.load(glb_path)
        print(f"--- Scene Information ---")
        print(f"File: {glb_path}")
        
        # Check for alignment metadata (specific to our DA3 output)
        if hasattr(scene, 'metadata') and 'hf_alignment' in scene.metadata:
            print("Detected hf_alignment metadata. Aligning scene to gravity...")
            A = np.array(scene.metadata['hf_alignment']).reshape(4, 4)
            
            # Calculate gravity vector in aligned space
            # Coordinate system: ARCore/OpenGL (Right, Up, Back)
            arcore_y = np.array([0, 1, 0])
            gl_to_cv = np.array([[1, 0, 0], [0, -1, 0], [0, 0, -1]])
            
            gravity = (A[:3, :3] @ gl_to_cv @ arcore_y)
            gravity = gravity / np.linalg.norm(gravity)
            
            # Align gravity to Z+ axis [0, 0, 1]
            R = Rotation.align_vectors([[0, 0, 1]], [gravity])[0]
            T = np.eye(4)
            T[:3, :3] = R.as_matrix()
            
            # Apply transformation
            scene.apply_transform(T)
            print("Scene aligned to Z+ (gravity) axis.")

        # Show the scene
        print("Opening visualization window...")
        scene.show()
        
    except Exception as e:
        print(f"Failed to visualize GLB: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    # If a path is provided, use it. Otherwise, look for the latest session in uploads.
    target_path = None
    
    if len(sys.argv) > 1:
        target_path = sys.argv[1]
    else:
        # Automatically find the latest scene.glb in the uploads directory
        upload_dir = "uploads"
        if os.path.exists(upload_dir):
            sessions = [d for d in os.listdir(upload_dir) if os.path.isdir(os.path.join(upload_dir, d))]
            if sessions:
                # Sort by modification time to find the newest
                sessions.sort(key=lambda d: os.path.getmtime(os.path.join(upload_dir, d)), reverse=True)
                latest_session = sessions[0]
                potential_path = os.path.join(upload_dir, latest_session, "output", "scene.glb")
                if os.path.exists(potential_path):
                    target_path = potential_path
                    print(f"No path provided. Using latest session: {latest_session}")
                else:
                    # Check root output if it exists
                    potential_path = os.path.join(upload_dir, latest_session, "scene.glb")
                    if os.path.exists(potential_path):
                        target_path = potential_path
                        print(f"No path provided. Using latest session: {latest_session}")

    if target_path:
        load_and_show_scene(target_path)
    else:
        print("Usage: python visualization.py <path_to_glb>")
        print("Example: python visualization.py uploads/<session_id>/output/scene.glb")
