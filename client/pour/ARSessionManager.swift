//
//  ARSessionManager.swift
//  pour
//
//  ARKit Session Management
//

import ARKit
import Combine

class ARSessionManager: NSObject, ObservableObject {
    let session = ARSession()
    
    @Published var currentFrame: ARFrame?
    @Published var isSessionReady = false
    @Published var trackingState: String = "Initializing..."
    
    // Recording & Filtering State
    @Published var isRecording = false
    private var lastCaptureTransform: simd_float4x4?
    private var lastCaptureTime: TimeInterval = 0
    
    // For Velocity Check
    private var prevFrameTransform: simd_float4x4?
    private var prevFrameTime: TimeInterval = 0
    
    enum FeedbackType {
        case ok
        case moveMore
        case slowDown
        case trackingLost
    }
    
    @Published var currentFeedback: FeedbackType = .ok
    @Published var capturedFramesCount: Int = 0
    
    override init() {
        super.init()
        session.delegate = self
    }
    
    func startSession() {
        let configuration = ARWorldTrackingConfiguration()
        
        // Find 4:3 video format if available
        if let videoFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
            let res = $0.imageResolution
            return abs(res.width / res.height - 4.0/3.0) < 0.1
        }) {
            configuration.videoFormat = videoFormat
            print("Selected 4:3 Video Format: \(videoFormat.imageResolution)")
        }
        
        configuration.planeDetection = []
        session.run(configuration)
    }
    
    func pauseSession() {
        session.pause()
    }
    
    /// ARKit의 매핑(지도 확장 및 좌표계 수정) 업데이트 여부를 설정합니다.
    /// - Parameter enabled: true이면 일반 트래킹, false이면 현재 좌표계를 고정합니다.
    func setWorldMapping(enabled: Bool) {
        let configuration = ARWorldTrackingConfiguration()
        
        // 기존 비디오 포맷 유지
        if let videoFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
            let res = $0.imageResolution
            return abs(res.width / res.height - 4.0/3.0) < 0.1
        }) {
            configuration.videoFormat = videoFormat
        }
        
        configuration.planeDetection = []
        
        if enabled {
            print("▶️ ARKit 매핑 활성화")
            session.run(configuration, options: [])
        } else {
            print("🛑 ARKit 매핑 고정 (Drift 방지)")
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                configuration.sceneReconstruction = []
            }
            // options를 빈 값으로 주어 현재 좌표계(Origin)를 고정합니다.
            session.run(configuration, options: [])
        }
    }
    
    // MARK: - Capture Photo with Metadata
    
    func capturePhoto() -> (imageData: Data, metadata: ARMetadata)? {
        guard let frame = currentFrame else { return nil }
        
        // Get camera transform (4x4 matrix)
        let transform = frame.camera.transform
        
        // Get camera intrinsics and image resolution
        var intrinsics = frame.camera.intrinsics
        var imageResolution = frame.camera.imageResolution
        
        // Convert ARFrame image to JPEG
        let pixelBuffer = frame.capturedImage
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Ensure 4:3 cropping if the source is not 4:3 (e.g. 16:9)
        let currentRatio = imageResolution.width / imageResolution.height
        let targetRatio: CGFloat = 4.0 / 3.0
        
        if abs(currentRatio - targetRatio) > 0.01 {
            let width = imageResolution.width
            let height = imageResolution.height
            
            var cropRect: CGRect
            if currentRatio > targetRatio {
                // Too wide (e.g. 16:9), crop sides
                let newWidth = height * targetRatio
                let xOffset = (width - newWidth) / 2
                cropRect = CGRect(x: xOffset, y: 0, width: newWidth, height: height)
                
                // Adjust intrinsics for cropping
                intrinsics[2, 0] -= Float(xOffset) // Principal point x
                imageResolution = CGSize(width: newWidth, height: height)
            } else {
                // Too tall, crop top/bottom
                let newHeight = width / targetRatio
                let yOffset = (height - newHeight) / 2
                cropRect = CGRect(x: 0, y: yOffset, width: width, height: newHeight)
                
                // Adjust intrinsics for cropping
                intrinsics[2, 1] -= Float(yOffset) // Principal point y
                imageResolution = CGSize(width: width, height: newHeight)
            }
            ciImage = ciImage.cropped(to: cropRect)
        }
        
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        guard let imageData = uiImage.jpegData(compressionQuality: 0.9) else {
            return nil
        }
        
        // Create metadata (DA3 compatible format)
        let metadata = ARMetadata(
            transform: transform,
            cameraIntrinsics: intrinsics,
            imageSize: imageResolution,
            timestamp: frame.timestamp
        )
        
        return (imageData, metadata)
    }
    
    // MARK: - Auto-Sampling Logic
    
    func checkShouldCapture(frame: ARFrame) -> (shouldCapture: Bool, feedback: FeedbackType) {
        // 1. Check Tracking State
        guard case .normal = frame.camera.trackingState else {
            return (false, .trackingLost)
        }
        
        // 2. Instantaneous Velocity Check (Blur Prevention)
        let currentTime = frame.timestamp
        if let prevTransform = prevFrameTransform, prevFrameTime > 0 {
            let deltaTime = currentTime - prevFrameTime
            if deltaTime > 0 {
                // Movement Speed (m/s)
                let moveDist = simd_distance(frame.camera.transform.columns.3, prevTransform.columns.3)
                let velocity = moveDist / Float(deltaTime)
                
                // Rotation Speed (deg/s)
                let prevQuat = simd_quatf(prevTransform)
                let currQuat = simd_quatf(frame.camera.transform)
                let dotProduct = abs(simd_dot(prevQuat.vector, currQuat.vector))
                let rotAngle = acos(min(dotProduct, 1.0)) * 2.0 * (180.0 / Float.pi)
                let angularVelocity = Double(rotAngle) / deltaTime
                
                // Thresholds: > 0.3 m/s or > 45 deg/s
                if velocity > 0.3 || angularVelocity > 45.0 {
                    // Update previous for next check and return
                    self.prevFrameTransform = frame.camera.transform
                    self.prevFrameTime = currentTime
                    return (false, .slowDown)
                }
            }
        }
        
        // Update previous frame state
        self.prevFrameTransform = frame.camera.transform
        self.prevFrameTime = currentTime
        
        // 3. Rate Limiting (Max 5 FPS = 0.2s)
        guard currentTime - lastCaptureTime >= 0.2 else {
            return (false, .ok)
        }
        
        // 4. Movement Check from LAST CAPTURED frame (Diversity)
        if let lastTransform = lastCaptureTransform {
            let currentTransform = frame.camera.transform
            
            // Calculate Distance (Translation)
            let distance = simd_distance(currentTransform.columns.3, lastTransform.columns.3)
            
            // Calculate Rotation Angle
            let lastQuat = simd_quatf(lastTransform)
            let currentQuat = simd_quatf(frame.camera.transform)
            let angle = acos(min(abs(simd_dot(lastQuat.vector, currentQuat.vector)), 1.0)) * 2.0 * (180.0 / .pi)
            
            // Thresholds: 5cm or 10 degrees
            if distance < 0.05 && angle < 10.0 {
                return (false, .moveMore)
            }
        }
        
        return (true, .ok)
    }
    
    func recordCapturedFrame(transform: simd_float4x4, time: TimeInterval) {
        self.lastCaptureTransform = transform
        self.lastCaptureTime = time
        self.capturedFramesCount += 1
    }
    
    func resetRecording() {
        self.lastCaptureTransform = nil
        self.lastCaptureTime = 0
        self.prevFrameTransform = nil
        self.prevFrameTime = 0
        self.capturedFramesCount = 0
        // isRecording is used for automatic sampling in Video mode
        self.isRecording = false
    }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        DispatchQueue.main.async {
            self.currentFrame = frame
            self.isSessionReady = true
            
            switch frame.camera.trackingState {
            case .normal:
                self.trackingState = "Ready"
            case .limited(let reason):
                switch reason {
                case .excessiveMotion:
                    self.trackingState = "Too fast"
                case .insufficientFeatures:
                    self.trackingState = "Low features"
                case .initializing:
                    self.trackingState = "Initializing..."
                case .relocalizing:
                    self.trackingState = "Relocalizing..."
                @unknown default:
                    self.trackingState = "Limited"
                }
            case .notAvailable:
                self.trackingState = "Not available"
            }
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.trackingState = "Error"
        }
    }
}
