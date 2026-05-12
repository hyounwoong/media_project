import os
import json
import glob
import logging

logger = logging.getLogger("DataConverter")

def convert_to_jsonl(session_path):
    """
    Reads all meta_*.json files in a session folder and combines them into metadata.jsonl.
    """
    meta_files = sorted(glob.glob(os.path.join(session_path, "meta_*.json")))
    if not meta_files:
        logger.warning(f"No meta_*.json files found in {session_path}")
        return None

    jsonl_path = os.path.join(session_path, "metadata.jsonl")
    
    with open(jsonl_path, "w") as out_f:
        for meta_path in meta_files:
            try:
                with open(meta_path, "r") as in_f:
                    data = json.load(in_f)
                    # Flatten intrinsics if needed
                    if "intrinsics" in data and isinstance(data["intrinsics"], dict):
                        for k, v in data["intrinsics"].items():
                            data[k] = v
                    
                    out_f.write(json.dumps(data) + "\n")
            except Exception as e:
                logger.error(f"Failed to process {meta_path}: {e}")
                continue
    
    logger.info(f"Created {jsonl_path} from {len(meta_files)} files.")
    return jsonl_path
