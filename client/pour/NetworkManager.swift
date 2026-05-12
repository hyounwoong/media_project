//
//  NetworkManager.swift
//  pour
//
//  Server Communication Layer
//

import Foundation
import Combine

class NetworkManager: ObservableObject {
    static let shared = NetworkManager()
    
    private let baseURL: String
    @Published var sessionUUID: String?
    @Published var uploadStatus: UploadStatus = .idle
    @Published var uploadCount: Int = 0
    @Published var pendingUploadCount: Int = 0 // [추가] 실시간 전송 중인 작업 수
    
    enum UploadStatus: Equatable {
        case idle
        case uploading(Int, Int) // (current, total)
        case success
        case failed(String)
    }
    
    @Published var serverStatus: ServerStatus = .unknown
    
    enum ServerStatus {
        case unknown
        case connected
        case disconnected
    }
    
    private init() {
        if let path = Bundle.main.path(forResource: "AppConfig", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let url = dict["BaseURL"] as? String {
            self.baseURL = url
        } else {
            // Fallback for development if AppConfig.plist is missing
            self.baseURL = "http://YOUR_SERVER_IP:PORT"
            print("Warning: AppConfig.plist not found, using fallback URL")
        }
    }
    
    // MARK: - Health Check (Handshake)
    
    func checkHealth() async {
        do {
            let url = try makeURL(path: "/health")
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["status"] as? String == "ok" {
                await MainActor.run {
                    self.serverStatus = .connected
                }
            } else {
                await MainActor.run {
                    self.serverStatus = .disconnected
                }
            }
        } catch {
            await MainActor.run {
                self.serverStatus = .disconnected
            }
        }
    }
    
    // MARK: - Session Registration
    
    func registerSession() async throws -> String {
        let url = try makeURL(path: "/session/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        // Debug server handles simple POST
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NetworkError.registrationFailed
        }
        
        let sessionResponse = try JSONDecoder().decode(SessionResponse.self, from: data)
        
        await MainActor.run {
            self.sessionUUID = sessionResponse.session_uuid
        }
        
        return sessionResponse.session_uuid
    }
    
    // MARK: - Photo Upload with AR Metadata
    
    func uploadPhoto(imageData: Data, metadata: ARMetadata) async throws {
        guard let uuid = sessionUUID else {
            throw NetworkError.noSession
        }
        
        let url = try makeURL(path: "/session/\(uuid)/upload")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add image file
        let filename = "photo_\(Int(metadata.timestamp * 1000)).jpg"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add metadata JSON
        let metadataJSON = try JSONEncoder().encode(metadata)
        let metadataString = String(data: metadataJSON, encoding: .utf8)!
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"metadata\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(metadataString)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        await MainActor.run {
            self.pendingUploadCount += 1
        }
        
        defer {
            DispatchQueue.main.async {
                if self.pendingUploadCount > 0 {
                    self.pendingUploadCount -= 1
                }
            }
        }
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NetworkError.uploadFailed
        }
        
        await MainActor.run {
            self.uploadCount += 1
        }
    }
    
    // MARK: - Batch Upload
    
    func uploadBatch(frames: [(Data, ARMetadata)]) async throws {
        let total = frames.count
        for (index, frame) in frames.enumerated() {
            await MainActor.run {
                self.uploadStatus = .uploading(index + 1, total)
            }
            try await uploadPhoto(imageData: frame.0, metadata: frame.1)
        }
        
        await MainActor.run {
            self.uploadStatus = .success
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.uploadStatus = .idle
            }
        }
    }
    
    // MARK: - Process Control (DA3)
    
    @Published var processStatus: ProcessStatus = .idle
    @Published var volumeResult: Double?
    @Published var cupBottomCenter: [Float]?  // Cup bottom center in ARKit world coordinates
    @Published var fillLineCenter: [Float]?   // Fill line center in ARKit world coordinates
    @Published var fillLineRadius: Float?     // Fill line radius for ring drawing
    @Published var volumeProfile: [VolumeSlice] = []
    
    struct VolumeSlice: Codable {
        let cumulative_ml: Double
        let radius: Float
        let center_arkit: [Float]?
    }
    

    
    enum ProcessStatus: Equatable {
        case idle
        case processing
        case completed
        case failed(String)
    }
    
    /// Trigger DA3 volume calculation
    func triggerProcess() async throws {
        guard let uuid = sessionUUID else {
            throw NetworkError.noSession
        }
        
        await MainActor.run {
            self.processStatus = .processing
        }
        
        let url = try makeURL(path: "/session/\(uuid)/process")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            await MainActor.run {
                self.processStatus = .failed("Process trigger failed")
            }
            throw NetworkError.processFailed
        }
    }
    
    /// Poll for process status
    func checkStatus() async throws -> String {
        guard let uuid = sessionUUID else {
            throw NetworkError.noSession
        }
        
        let url = try makeURL(path: "/session/\(uuid)/status")
        let (data, _) = try await URLSession.shared.data(from: url)
        let statusResponse = try JSONDecoder().decode(StatusResponse.self, from: data)
        
        return statusResponse.status
    }
    
    /// Get volume result
    func getResult() async throws -> Double {
        guard let uuid = sessionUUID else {
            throw NetworkError.noSession
        }
        
        let url = try makeURL(path: "/session/\(uuid)/result")
        let (data, _) = try await URLSession.shared.data(from: url)
        let resultResponse = try JSONDecoder().decode(ResultResponse.self, from: data)
        
        guard let volume = resultResponse.volume_ml else {
            throw NetworkError.noResult
        }
        
        await MainActor.run {
            self.volumeResult = volume
            self.cupBottomCenter = resultResponse.cup_bottom_center
            self.volumeProfile = resultResponse.volume_profile ?? []
            self.processStatus = .completed
            
            if let center = resultResponse.cup_bottom_center {
                print("Cup bottom center (ARKit): x=\(center[0]), y=\(center[1]), z=\(center[2])")
            }
            
            // Initial fill line calculation
            if volume >= 100 {
                updateFillHeightLocally(targetMl: 100)
            } else {
                updateFillHeightLocally(targetMl: volume / 2)
            }
        }
        
        return volume
    }
    
    /// Process and wait for result (with polling)
    func processAndWaitForResult() async throws -> Double {
        try await triggerProcess()
        
        // Poll for completion (max 5 minutes)
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            
            let status = try await checkStatus()
            if status == "completed" {
                return try await getResult()
            } else if status == "failed" {
                await MainActor.run {
                    self.processStatus = .failed("Processing failed")
                }
                throw NetworkError.processFailed
            }
        }
        
        throw NetworkError.timeout
    }
    
    /// Get fill line position for a target volume
    func getFillHeight(targetMl: Double) async throws {
        // Fallback to local calculation if profile exists
        if !volumeProfile.isEmpty {
            await MainActor.run {
                updateFillHeightLocally(targetMl: targetMl)
            }
            return
        }
        
        guard let uuid = sessionUUID else {
            throw NetworkError.noSession
        }
        
        let url = try makeURL(path: "/session/\(uuid)/fill-height?target_ml=\(targetMl)")
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(FillHeightResponse.self, from: data)
        
        await MainActor.run {
            if response.status == "success" {
                self.fillLineCenter = response.fill_line_center
                self.fillLineRadius = response.fill_line_radius
                print("Fill line at \(targetMl)mL: center=\(response.fill_line_center ?? []), radius=\(response.fill_line_radius ?? 0)")
            } else if response.status == "exceeded" {
                print("Target \(targetMl)mL exceeds max volume \(response.max_volume_ml ?? 0)mL")
                self.fillLineCenter = nil
                self.fillLineRadius = nil
            } else {
                print("Fill height error: \(response.message ?? "unknown")")
            }
        }
    }
    
    /// Update fill height locally using interpolation (Smooth UX)
    func updateFillHeightLocally(targetMl: Double) {
        guard !volumeProfile.isEmpty else { return }
        
        // Find the bracket
        var lower: VolumeSlice?
        var upper: VolumeSlice?
        
        for i in 0..<volumeProfile.count {
            if volumeProfile[i].cumulative_ml >= targetMl {
                upper = volumeProfile[i]
                if i > 0 {
                    lower = volumeProfile[i-1]
                }
                break
            }
        }
        
        // Handle edges
        if upper == nil {
            upper = volumeProfile.last
        }
        
        if lower == nil {
            if let first = volumeProfile.first {
                self.fillLineCenter = first.center_arkit
                self.fillLineRadius = first.radius
            }
            return
        }
        
        guard let l = lower, let u = upper else { return }
        
        // Linear interpolation
        let totalVolumeDiff = u.cumulative_ml - l.cumulative_ml
        let t = totalVolumeDiff > 0 ? Float((targetMl - l.cumulative_ml) / totalVolumeDiff) : 0.0
        
        if let lCenter = l.center_arkit, let uCenter = u.center_arkit {
            let cx = lCenter[0] + t * (uCenter[0] - lCenter[0])
            let cy = lCenter[1] + t * (uCenter[1] - lCenter[1])
            let cz = lCenter[2] + t * (uCenter[2] - lCenter[2])
            self.fillLineCenter = [cx, cy, cz]
        }
        
        self.fillLineRadius = l.radius + t * (u.radius - l.radius)
    }
    
    // MARK: - Helpers
    
    private func makeURL(path: String) throws -> URL {
        let urlString = "\(baseURL)\(path)"
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL(urlString)
        }
        return url
    }
    
    // MARK: - Errors
    
    enum NetworkError: Error, LocalizedError {
        case invalidURL(String)
        case registrationFailed
        case noSession
        case uploadFailed
        case processFailed
        case noResult
        case timeout
        
        var errorDescription: String? {
            switch self {
            case .invalidURL(let url): return "Invalid URL: \(url). Please check AppConfig.plist."
            case .registrationFailed: return "Session registration failed"
            case .noSession: return "No active session"
            case .uploadFailed: return "Photo upload failed"
            case .processFailed: return "Volume processing failed"
            case .noResult: return "No result available"
            case .timeout: return "Processing timeout"
            }
        }
    }
}
