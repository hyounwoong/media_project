import os
import uuid
import json
import logging
from typing import Dict
from fastapi import FastAPI, UploadFile, File, Form, HTTPException, BackgroundTasks
from fastapi.responses import JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import sys
sys.path.insert(0, '/workspace/Depth-Anything-3/src')

# Import our new modules
import data_converter
import da3_module
import volume_calculator

# Setup Logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("PourServer")

app = FastAPI(title="Pour AR Server")

@app.on_event("startup")
async def startup_event():
    """Load the DA3 model during server startup."""
    logger.info("Server starting up... Pre-loading DA3 model.")
    try:
        da3_module.get_da3_model()
        logger.info("DA3 model pre-loaded successfully.")
    except Exception as e:
        logger.error(f"Failed to pre-load DA3 model on startup: {e}")
        # We don't exit; it might load later or run on CPU

# Storage directory
UPLOAD_DIR = "uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)

# Shared state to track processing status
# In a real app, use Redis or a DB
processing_results: Dict[str, dict] = {}

class ProcessResponse(BaseModel):
    status: str
    message: str
    volume_ml: float = 0.0

@app.get("/health")
async def health_check():
    """Handshake endpoint to verify server status."""
    logger.info("Health check received.")
    return {"status": "ok", "message": "Server is running"}

@app.post("/session/register")
async def register_session():
    """Register a new session and return a UUID."""
    session_id = str(uuid.uuid4())
    session_path = os.path.join(UPLOAD_DIR, session_id)
    os.makedirs(session_path, exist_ok=True)
    logger.info(f"New session registered: {session_id}")
    return {
        "status": "success",
        "session_uuid": session_id,
        "message": "Session created"
    }

@app.post("/session/{session_uuid}/upload")
async def upload_data(
    session_uuid: str,
    file: UploadFile = File(...),
    metadata: str = Form(...)
):
    """Receive image and metadata, and save them to the session directory."""
    session_path = os.path.join(UPLOAD_DIR, session_uuid)
    if not os.path.exists(session_path):
        raise HTTPException(status_code=404, detail="Session not found")

    try:
        meta_dict = json.loads(metadata)
        timestamp = meta_dict.get("timestamp", uuid.uuid4().hex)
        
        # Save Metadata
        meta_filename = f"meta_{timestamp}.json"
        with open(os.path.join(session_path, meta_filename), "w") as f:
            json.dump(meta_dict, f, indent=4)
            
        # Save Image
        img_filename = f"img_{timestamp}.jpg"
        with open(os.path.join(session_path, img_filename), "wb") as f:
            f.write(await file.read())
            
        return {"status": "success", "filename": img_filename}
    except Exception as e:
        logger.error(f"Upload failed: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

async def background_process_session(session_uuid: str):
    """Background task to run 3D reconstruction and volume calculation."""
    session_path = os.path.join(UPLOAD_DIR, session_uuid)
    processing_results[session_uuid] = {"status": "processing", "volume_ml": 0.0}
    
    try:
        # 1. Convert individual JSONs to metadata.jsonl
        logger.info(f"[{session_uuid}] Converting data...")
        data_converter.convert_to_jsonl(session_path)
        
        # 2. Run DA3 Reconstruction
        logger.info(f"[{session_uuid}] Starting DA3 Reconstruction...")
        da3_module.run_da3_reconstruction(session_path)
        
        # 3. Run Volume Calculation
        logger.info(f"[{session_uuid}] Calculating Volume...")
        volume_ml, msg, cup_bottom, volume_profile, calc_metadata = volume_calculator.calculate_volume(session_path)
        
        if msg == "Success":
            processing_results[session_uuid] = {
                "status": "completed",
                "volume_ml": round(volume_ml, 2),
                "cup_bottom_center": cup_bottom.tolist() if cup_bottom is not None else None,
                "calc_metadata": calc_metadata,  # Store for fill-height calculations
                "message": msg
            }
            logger.info(f"[{session_uuid}] Completed. Volume: {volume_ml:.2f} mL, Bottom: {cup_bottom}")
        else:
            processing_results[session_uuid] = {
                "status": "failed",
                "message": msg
            }
            logger.error(f"[{session_uuid}] Calculation failed: {msg}")
            
    except Exception as e:
        logger.error(f"[{session_uuid}] Pipeline error: {str(e)}")
        processing_results[session_uuid] = {
            "status": "failed",
            "message": f"Error: {str(e)}"
        }

@app.post("/session/{session_uuid}/process")
async def process_session(session_uuid: str, background_tasks: BackgroundTasks):
    """Trigger the processing pipeline for a session."""
    session_path = os.path.join(UPLOAD_DIR, session_uuid)
    if not os.path.exists(session_path):
        raise HTTPException(status_code=404, detail="Session not found")
    
    background_tasks.add_task(background_process_session, session_uuid)
    return {"status": "processing", "message": "Background processing started"}

@app.get("/session/{session_uuid}/status")
async def get_status(session_uuid: str):
    """Alias for get_result for client compatibility."""
    return await get_result(session_uuid)

@app.get("/session/{session_uuid}/result")
async def get_result(session_uuid: str):
    """Get the result of the processing pipeline."""
    result = processing_results.get(session_uuid)
    if not result:
        # If not in memory, check if output files exist as fallback
        scene_exists = os.path.exists(os.path.join(UPLOAD_DIR, session_uuid, "output", "scene.glb"))
        if scene_exists:
            return {"status": "unknown", "message": "Result in memory lost, but output files exist."}
        return {"status": "not_found", "message": "Session result not found"}
    
    # Remove calc_metadata from response (internal use only)
    response = {k: v for k, v in result.items() if k != 'calc_metadata'}
    return response


@app.get("/session/{session_uuid}/fill-height")
async def get_fill_height(session_uuid: str, target_ml: float):
    """Get the fill line position for a target volume."""
    result = processing_results.get(session_uuid)
    if not result or result.get("status") != "completed":
        return {"status": "error", "message": "No completed result for this session"}
    
    calc_metadata = result.get("calc_metadata")
    if not calc_metadata:
        return {"status": "error", "message": "Calculation metadata not available"}
    
    volume_profile = calc_metadata.get('volume_profile')
    center_axis = calc_metadata.get('center_axis')
    first_frame = calc_metadata.get('first_frame')
    scene_metadata = calc_metadata.get('scene_metadata')
    
    if not volume_profile:
        return {"status": "error", "message": "Volume profile not available"}
    
    # Check if target exceeds max volume
    max_ml = result.get("volume_ml", 0)
    if target_ml > max_ml:
        return {
            "status": "exceeded",
            "message": f"Target {target_ml}mL exceeds max volume {max_ml}mL",
            "max_volume_ml": max_ml
        }
    
    # Calculate fill height
    import numpy as np
    center_axis = np.array(center_axis)
    
    height_arkit, radius = volume_calculator.find_height_for_volume(
        volume_profile, target_ml, center_axis, first_frame, scene_metadata
    )
    
    if height_arkit is None:
        return {"status": "error", "message": "Failed to calculate fill height"}
    
    return {
        "status": "success",
        "target_ml": target_ml,
        "fill_line_center": height_arkit,
        "fill_line_radius": radius
    }


# --- Dashboard APIs ---

@app.get("/api/sessions")
async def list_sessions():
    """List all sessions in the upload directory."""
    sessions = []
    if not os.path.exists(UPLOAD_DIR):
        return sessions
        
    for session_id in os.listdir(UPLOAD_DIR):
        path = os.path.join(UPLOAD_DIR, session_id)
        if os.path.isdir(path):
            # Check for existing results
            status = "unknown"
            if session_id in processing_results:
                status = processing_results[session_id].get("status", "unknown")
            else:
                # Check for output files as fallback
                if os.path.exists(os.path.join(path, "output", "scene.glb")):
                    status = "completed"
            
            sessions.append({
                "uuid": session_id,
                "status": status,
                "time": os.path.getmtime(path)
            })
    
    # Sort by time, newest first
    sessions.sort(key=lambda x: x['time'], reverse=True)
    return sessions

@app.get("/api/sessions/{session_uuid}")
async def get_session_details(session_uuid: str):
    """Get detailed files for a session to show in dashboard."""
    session_path = os.path.join(UPLOAD_DIR, session_uuid)
    if not os.path.exists(session_path):
        raise HTTPException(status_code=404, detail="Session not found")
        
    images = [f for f in os.listdir(session_path) if f.startswith("img_") and f.endswith(".jpg")]
    images.sort()
    
    glb_path = os.path.join("output", "scene.glb")
    has_glb = os.path.exists(os.path.join(session_path, glb_path))
    
    debug_json_path = "volume_debug.json"
    debug_data = None
    if os.path.exists(os.path.join(session_path, debug_json_path)):
        try:
            with open(os.path.join(session_path, debug_json_path), 'r') as f:
                debug_data = json.load(f)
        except:
            pass

    return {
        "uuid": session_uuid,
        "images": images,
        "has_glb": has_glb,
        "glb_url": f"/data/{session_uuid}/output/scene.glb" if has_glb else None,
        "debug_data": debug_data,
        "status": processing_results.get(session_uuid, {}).get("status", "unknown")
    }

@app.get("/dashboard")
async def serve_dashboard():
    """Serve the dashboard HTML file."""
    dashboard_path = os.path.join("static", "dashboard.html")
    if not os.path.exists(dashboard_path):
        return JSONResponse({"status": "error", "message": "Dashboard UI not found"}, status_code=404)
    return FileResponse(dashboard_path)

# Static files mounting
os.makedirs("static", exist_ok=True)
app.mount("/static", StaticFiles(directory="static"), name="static")
app.mount("/data", StaticFiles(directory=UPLOAD_DIR), name="data")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8888)
