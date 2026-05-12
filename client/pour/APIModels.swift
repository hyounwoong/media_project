//
//  APIModels.swift
//  pour
//
//  AR Photo Upload Models (DA3 Compatible)
//

import Foundation
import simd

// MARK: - AR Metadata (DA3 Compatible Format)

struct CameraIntrinsics: Codable {
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
}

struct ARMetadata: Codable {
    let pos: [Float]              // Camera position [x, y, z]
    let quat: [Float]             // Camera rotation quaternion [qx, qy, qz, qw]
    let intrinsics: CameraIntrinsics
    let w: Int                    // Image width
    let h: Int                    // Image height
    let timestamp: Double
    
    init(transform: simd_float4x4, cameraIntrinsics: simd_float3x3, imageSize: CGSize, timestamp: TimeInterval) {
        // Extract position from transform matrix (column 3)
        self.pos = [transform.columns.3.x, transform.columns.3.y, transform.columns.3.z]
        
        // Extract rotation as quaternion
        let rotation = simd_quatf(transform)
        self.quat = [rotation.vector.x, rotation.vector.y, rotation.vector.z, rotation.vector.w]
        
        self.intrinsics = CameraIntrinsics(
            fx: cameraIntrinsics[0][0],
            fy: cameraIntrinsics[1][1],
            cx: cameraIntrinsics[2][0],
            cy: cameraIntrinsics[2][1]
        )
        
        self.w = Int(imageSize.width)
        self.h = Int(imageSize.height)
        self.timestamp = timestamp
    }
}

// MARK: - Session Response

struct SessionResponse: Codable {
    let status: String
    let session_uuid: String
    let message: String?
}

// MARK: - Upload Response

struct UploadResponse: Codable {
    let status: String
    let filename: String?
    let size_bytes: Int?
    let metadata_saved: Bool?
}

// MARK: - Process Response

struct ProcessResponse: Codable {
    let status: String
    let message: String?
}

// MARK: - Status Response

struct StatusResponse: Codable {
    let status: String           // "idle", "processing", "completed", "failed"
    let progress: Double?        // 0.0 - 1.0
    let message: String?
}

// MARK: - Result Response

struct ResultResponse: Codable {
    let status: String
    let volume_ml: Double?
    let cup_bottom_center: [Float]?  // [x, y, z] ARKit world coordinates
    let volume_profile: [NetworkManager.VolumeSlice]? // [Added] For client-side interpolation
    let message: String?
}

// MARK: - Fill Height Response

struct FillHeightResponse: Codable {
    let status: String
    let target_ml: Double?
    let fill_line_center: [Float]?  // [x, y, z] ARKit world coordinates
    let fill_line_radius: Float?    // Radius for ring drawing
    let max_volume_ml: Double?      // When status is "exceeded"
    let message: String?
}
