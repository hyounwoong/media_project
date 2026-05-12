//
//  ContentView.swift
//  pour
//
//  AR Photo Upload App with DA3 Volume Calculation
//

import SwiftUI
import ARKit

struct ContentView: View {
    @StateObject private var sessionManager = ARSessionManager()
    @StateObject private var networkManager = NetworkManager.shared
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showResult = false
    @State private var localCapturedFrames: [(Data, ARMetadata)] = []
    @State private var isProcessingLocally = false
    @State private var targetMlValue: Double = 100  // For fill line slider
    @State private var captureMode: CaptureMode = .photo
    
    enum CaptureMode: String, CaseIterable {
        case photo = "사진"
        case video = "동영상"
    }
    
    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            let cameraWidth = screenWidth
            let cameraHeight = screenWidth * (4/3)
            let topBarHeight = (screenHeight - cameraHeight) / 2
            let bottomBarHeight = screenHeight - cameraHeight - topBarHeight
            
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                
                // AR Camera View (Centered 4:3 Area)
                ARCameraView(
                    sessionManager: sessionManager,
                    cupBottomCenter: networkManager.cupBottomCenter,
                    fillLineCenter: networkManager.fillLineCenter,
                    fillLineRadius: networkManager.fillLineRadius,
                    targetMl: targetMlValue
                )
                    .frame(width: cameraWidth, height: cameraHeight)
                    .clipped()
                    .position(x: screenWidth / 2, y: screenHeight / 2)
                
                // Top Letterbox Area
                VStack {
                    HStack {
                        statusBadge(
                            icon: nil,
                            text: sessionManager.trackingState,
                            color: statusColor
                        )
                        
                        statusBadge(
                            icon: networkManager.serverStatus == .connected ? "link" : "link.badge.plus",
                            text: networkManager.serverStatus == .connected ? "서버 연결됨" : "서버 연결 중...",
                            color: networkManager.serverStatus == .connected ? .green : .orange
                        )
                        
                        Spacer()
                        
                        // Session ID/Mode Indicator could go here
                        Text("4:3")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.yellow)
                    }
                    .padding(.horizontal)
                    .padding(.top, geometry.safeAreaInsets.top > 0 ? 0 : 10)
                }
                .frame(height: topBarHeight)
                .background(Color.black.opacity(0.8))
                
                // Compact Loading Overlay (Moved above mode selector)
                let isUploading: Bool = {
                    if case .uploading = networkManager.uploadStatus { return true }
                    return false
                }()
                
                if (networkManager.processStatus == .processing || isProcessingLocally || isUploading) && networkManager.volumeResult == nil {
                    VStack {
                        HStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(.white)
                            
                            let loadingText: String = {
                                if case .uploading(let current, let total) = networkManager.uploadStatus {
                                    return "전송 중 (\(current)/\(total))"
                                } else {
                                    return "계산 중..."
                                }
                            }()
                            
                            Text(loadingText)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(20)
                    }
                    .position(x: screenWidth / 2, y: topBarHeight + cameraHeight - 85)
                    .zIndex(100)
                }
                
                // Compact Result UI (Horizontal Bar)
                if let volume = networkManager.volumeResult {
                    HStack(spacing: 12) {
                        // Total Volume
                        VStack(alignment: .center, spacing: 0) {
                            Text("총")
                                .font(.system(size: 8))
                            Text(String(format: "%.0fml", volume))
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(width: 45)
                        
                        // Slider Volume (Current Target)
                        VStack(alignment: .center, spacing: 0) {
                            Text("선택")
                                .font(.system(size: 8))
                            Text("\(Int(targetMlValue))ml")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.orange)
                        .frame(width: 45)
                        
                        // Slider
                        Slider(value: $targetMlValue, in: 10...volume, step: 10)
                            .tint(.orange)
                            .frame(width: 100)
                        
                        // Show Button
                        Button(action: {
                            Task { try? await networkManager.getFillHeight(targetMl: targetMlValue) }
                        }) {
                            Text("표시")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.orange)
                                .cornerRadius(8)
                        }
                        .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(25)
                    .position(x: screenWidth / 2, y: topBarHeight + cameraHeight - 85)
                    .zIndex(100)
                }
                
                // Guidance Feedback Overlay (Moved to TOP)
                if sessionManager.isRecording {
                    VStack {
                        feedbackText
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(10)
                            .padding(.top, topBarHeight + 20) // Positioned below top bar
                        Spacer()
                    }
                    .frame(width: cameraWidth, height: cameraHeight)
                    .position(x: screenWidth / 2, y: screenHeight / 2)
                    .zIndex(45)
                }
                
                // Flash Effect for Capture
                if isProcessingLocally {
                    Color.white.opacity(0.3)
                        .ignoresSafeArea()
                        .zIndex(100)
                }
                
                // Floating Mode Selector & Frame Count (Above bottom letterbox)
                if !showResult {
                    ZStack {
                        // Left: Frame Count Badge
                        HStack {
                            if !localCapturedFrames.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "photo.stack")
                                    Text("\(localCapturedFrames.count)장")
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.8))
                                .cornerRadius(12)
                            }
                            Spacer()
                        }
                        .padding(.leading, 20)
                        
                        // Center: Mode Selector
                        HStack(spacing: 20) {
                            ForEach(CaptureMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue)
                                    .font(.system(size: 14, weight: captureMode == mode ? .bold : .medium))
                                    .foregroundColor(captureMode == mode ? .yellow : .white)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 12)
                                    .background(captureMode == mode ? Color.black.opacity(0.4) : Color.clear)
                                    .cornerRadius(15)
                                    .onTapGesture {
                                        if !sessionManager.isRecording {
                                            captureMode = mode
                                        }
                                    }
                            }
                        }
                        .padding(4)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(20)
                    }
                    .frame(width: screenWidth)
                    .position(x: screenWidth / 2, y: topBarHeight + cameraHeight - 35)
                    .zIndex(60)
                }

                // Bottom Letterbox Area (Controls)
                VStack {
                    Spacer()
                    
                    // Bottom Controls Overlay
                    if !showResult {
                        VStack(spacing: 20) {
                            HStack(spacing: 40) {
                                // Reset Button (Left)
                                Button(action: resetSession) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "arrow.counterclockwise.circle.fill")
                                            .font(.system(size: 32))
                                        Text("초기화")
                                            .font(.caption2)
                                    }
                                    .foregroundColor(.white.opacity(0.7))
                                }
                                .disabled(sessionManager.isRecording)
                                .frame(width: 60)
                                
                                // Integrated Shutter Button (Center)
                                Button(action: handleShutterAction) {
                                    ZStack {
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 4)
                                            .frame(width: 80, height: 80)
                                        
                                        if captureMode == .video && sessionManager.isRecording {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(.red)
                                                .frame(width: 35, height: 35)
                                        } else {
                                            Circle()
                                                .fill(captureMode == .video ? .red : .white)
                                                .frame(width: 65, height: 65)
                                        }
                                    }
                                }
                                .disabled(!sessionManager.isSessionReady || networkManager.serverStatus != .connected)
                                
                                // Calculate Button (Right)
                                Button(action: startProcessing) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 32))
                                            .foregroundColor(localCapturedFrames.count >= 2 ? .green : .gray)
                                        Text("계산")
                                            .font(.caption2)
                                            .foregroundColor(localCapturedFrames.count >= 2 ? .white : .gray)
                                    }
                                }
                                .disabled(localCapturedFrames.count < 2 || networkManager.processStatus == .processing || isProcessingLocally || sessionManager.isRecording)
                                .frame(width: 60)
                            }
                        }
                    }
                    
                    Spacer()
                }
                .frame(height: bottomBarHeight)
                .position(x: screenWidth / 2, y: screenHeight - bottomBarHeight / 2)
            }
        }
        .onAppear {
            sessionManager.startSession()
            Task {
                await networkManager.checkHealth()
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Subviews
    
    private func statusBadge(icon: String?, text: String, color: Color?) -> some View {
        HStack(spacing: 6) {
            if let color = color {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            }
            if let icon = icon {
                Image(systemName: icon)
            }
            Text(text)
        }
        .font(.caption)
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }
    
    @ViewBuilder
    private var statusFeedback: some View {
        switch networkManager.uploadStatus {
        case .uploading(let current, let total):
            VStack {
                ProgressView(value: Double(current), total: Double(total))
                    .progressViewStyle(LinearProgressViewStyle(tint: .white))
                    .frame(width: 100)
                Text("데이터 전송 중 (\(current)/\(total))")
                    .font(.caption2)
                    .foregroundColor(.white)
            }
        case .success:
            HStack {
                Image(systemName: "checkmark.circle.fill")
                Text("전송 완료")
            }
            .foregroundColor(.green)
            .font(.caption)
        case .failed(let msg):
            Text(msg)
                .font(.caption)
                .foregroundColor(.red)
        case .idle:
            EmptyView()
        }
    }
    
    @ViewBuilder
    private var feedbackText: some View {
        switch sessionManager.currentFeedback {
        case .ok:
            Text("천천히 움직여주세요")
        case .moveMore:
            Text("각도를 더 바꿔보세요")
        case .slowDown:
            Text("너무 빨라요!")
        case .trackingLost:
            Text("주변을 인식 중입니다...")
        }
    }
    
    // MARK: - Computed Properties
    
    private var statusColor: Color {
        switch sessionManager.trackingState {
        case "Ready": return .green
        case "Initializing...", "Relocalizing...": return .yellow
        default: return .red
        }
    }
    
    private var canCapture: Bool {
        sessionManager.isSessionReady &&
        networkManager.processStatus != .processing
    }
    
    // MARK: - Actions
    
    private func registerSession() {
        Task {
            do {
                _ = try await networkManager.registerSession()
            } catch {
                errorMessage = "Failed to register session: \(error.localizedDescription)"
                showError = true
            }
        }
    }
    
    private func handleShutterAction() {
        if captureMode == .photo {
            manualCapture()
        } else {
            toggleRecording()
        }
    }

    private func toggleRecording() {
        if sessionManager.isRecording {
            sessionManager.isRecording = false
            print("녹화 종료. 총 프레임: \(localCapturedFrames.count)")
        } else {
            // 1. UI 즉시 반응 및 매핑 고정
            sessionManager.isRecording = true
            sessionManager.setWorldMapping(enabled: false)
            
            // 2. [개선] 첫 번째 프레임 즉시 캡처 (개수 표시 즉시 반영)
            let firstFrameData = sessionManager.capturePhoto()
            if let (imageData, metadata) = firstFrameData {
                localCapturedFrames.append((imageData, metadata))
                if let frame = sessionManager.currentFrame {
                    sessionManager.recordCapturedFrame(transform: frame.camera.transform, time: frame.timestamp)
                }
            }
            
            // 3. 백그라운드 세션 등록 및 후속 처리
            Task {
                do {
                    if localCapturedFrames.count <= 1 { // 새로 시작하는 경우만
                        networkManager.cupBottomCenter = nil
                    }
                    
                    _ = try await networkManager.registerSession()
                    
                    // 4. 첫 번째로 찍어둔 프레임 즉시 업로드
                    if let firstFrame = firstFrameData {
                        try? await networkManager.uploadPhoto(imageData: firstFrame.0, metadata: firstFrame.1)
                    }
                    
                    await MainActor.run {
                        // 5. 이후 후속 샘플링 시작
                        startSampling()
                    }
                } catch {
                    print("세션 등록 실패: \(error)")
                    await MainActor.run {
                        sessionManager.isRecording = false
                        sessionManager.setWorldMapping(enabled: true)
                        errorMessage = "서버 연결에 실패했습니다."
                        showError = true
                    }
                }
            }
        }
    }
    
    private func startSampling() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            guard sessionManager.isRecording else {
                timer.invalidate()
                return
            }
            
            if let frame = sessionManager.currentFrame {
                let check = sessionManager.checkShouldCapture(frame: frame)
                
                DispatchQueue.main.async {
                    sessionManager.currentFeedback = check.feedback
                }
                
                if check.shouldCapture {
                    if let (imageData, metadata) = sessionManager.capturePhoto() {
                        DispatchQueue.main.async {
                            localCapturedFrames.append((imageData, metadata))
                            sessionManager.recordCapturedFrame(transform: frame.camera.transform, time: frame.timestamp)
                            
                            // [실시간 전송] 백그라운드 태스크로 즉시 전송
                            Task {
                                try? await networkManager.uploadPhoto(imageData: imageData, metadata: metadata)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func manualCapture() {
        guard let frame = sessionManager.currentFrame else { return }
        
        // Quality check (Warning only)
        let check = sessionManager.checkShouldCapture(frame: frame)
        sessionManager.currentFeedback = check.feedback
        
        // [추가] 첫 사진 촬영 시 매핑 고정
        if localCapturedFrames.isEmpty {
            sessionManager.setWorldMapping(enabled: false)
        }

        if let (imageData, metadata) = sessionManager.capturePhoto() {
            // Visual feedback (flash)
            isProcessingLocally = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isProcessingLocally = false
            }
            
            localCapturedFrames.append((imageData, metadata))
            sessionManager.recordCapturedFrame(transform: frame.camera.transform, time: frame.timestamp)
            
            // [실시간 전송] 사진 촬영 즉시 전송
            Task {
                do {
                    if networkManager.sessionUUID == nil {
                        _ = try await networkManager.registerSession()
                    }
                    try await networkManager.uploadPhoto(imageData: imageData, metadata: metadata)
                } catch {
                    print("사진 업로드 실패: \(error)")
                }
            }
        }
    }
    
    private func startProcessing() {
        Task {
            isProcessingLocally = true
            do {
                // [수정] 이미 실시간으로 업로드 중이므로, 남은 전송이 있다면 완료될 때까지 대기
                while networkManager.pendingUploadCount > 0 {
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5초 대기
                    print("남은 전송 대기 중... (\(networkManager.pendingUploadCount))")
                }
                
                localCapturedFrames.removeAll()
                
                // Trigger 3D Reconstruction and Volume Calculation (Seol's logic)
                let volume = try await networkManager.processAndWaitForResult()
                
                await MainActor.run {
                    isProcessingLocally = false
                    
                    // Automatically show 100ml fill line if volume allows
                    if volume >= 100 {
                        targetMlValue = 100
                        Task {
                            try? await networkManager.getFillHeight(targetMl: 100)
                        }
                    } else if volume > 10 {
                        targetMlValue = volume / 2
                        Task {
                            try? await networkManager.getFillHeight(targetMl: targetMlValue)
                        }
                    }
                }
                
            } catch {
                errorMessage = "데이터 전송 실패: \(error.localizedDescription)"
                showError = true
                isProcessingLocally = false
            }
        }
    }
    
    private func resetSession() {
        showResult = false
        networkManager.uploadCount = 0
        networkManager.volumeResult = nil
        networkManager.cupBottomCenter = nil  // Clear AR marker
        networkManager.fillLineCenter = nil   // Clear AR ring center
        networkManager.fillLineRadius = 0      // Clear AR ring radius
        networkManager.processStatus = .idle
        networkManager.sessionUUID = nil // Clear session
        
        // [추가] 초기화 시 매핑 다시 활성화
        sessionManager.setWorldMapping(enabled: true)
    }
}

#Preview {
    ContentView()
}
