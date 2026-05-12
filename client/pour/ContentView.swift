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
    @Namespace private var modeAnimation
    @State private var captureMode: CaptureMode = .photo
    
    // ✨ 드래그 위치를 기억하는 변수
    @State private var cardOffset: CGSize = .zero
    @State private var lastCardOffset: CGSize = .zero
    
    enum CaptureMode: String, CaseIterable {
        case photo = "사진"
        case video = "동영상"
    }
    
    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            
            ZStack {
                Color.black.ignoresSafeArea()
                
                // 1. AR Camera View (Fullscreen)
                ARCameraView(
                    sessionManager: sessionManager,
                    cupBottomCenter: networkManager.cupBottomCenter,
                    fillLineCenter: networkManager.fillLineCenter,
                    fillLineRadius: networkManager.fillLineRadius,
                    targetMl: targetMlValue
                )
                .ignoresSafeArea()
                
                // 2. Top Status Badges (Moved to absolute top)
                HStack(spacing: 8) {
                    statusBadge(icon: nil, text: "Tracking: \(sessionManager.trackingState)", color: statusColor)
                    statusBadge(icon: "link", text: networkManager.serverStatus == .connected ? "Connected" : "Connecting...", color: networkManager.serverStatus == .connected ? .green : .orange)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .position(x: screenWidth / 2, y: geometry.safeAreaInsets.top + 15)
                .zIndex(100)
                
                // 3. Compact Loading Overlay
                let isUploading: Bool = {
                    if case .uploading = networkManager.uploadStatus { return true }
                    return false
                }()
                
                if (networkManager.processStatus == .processing || isProcessingLocally || isUploading) && networkManager.volumeResult == nil {
                    VStack {
                        HStack(spacing: 12) {
                            ProgressView().scaleEffect(0.8).tint(.white)
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
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                    }
                    .position(x: screenWidth / 2, y: screenHeight - 220)
                    .zIndex(100)
                }
                
                // 4. Circular Measurement Result (Camera Zoom Style Dial)
                if let volume = networkManager.volumeResult {
                    CircularDialPicker(value: $targetMlValue, range: 10...volume, onCommit: {
                        // 다이얼 조작이 끝나는 즉시 서버에 링 높이 계산을 요청
                        Task { try? await networkManager.getFillHeight(targetMl: targetMlValue) }
                    })
                    .frame(width: screenWidth, height: 150)
                    // 하단 모드 셀렉터(y: -160)보다 위로 배치
                    .position(x: screenWidth / 2, y: screenHeight - 280)
                    .zIndex(100)
                }
                
                // 5. Guidance Feedback Overlay
                if sessionManager.isRecording {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(8)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                feedbackText
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("Align the crosshair and capture angles.")
                                    .font(.system(size: 15))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            Spacer()
                        }
                    }
                    .padding(20)
                    .background(Color.white.opacity(0.1))
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                    .padding(.horizontal, 20)
                    .position(x: screenWidth / 2, y: screenHeight - 200)
                    .zIndex(45)
                }
                
                // 6. Flash Effect for Capture
                if isProcessingLocally {
                    Color.white.opacity(0.3)
                        .ignoresSafeArea()
                        .zIndex(100)
                }
                
                // 7. Floating Mode Selector
                if !showResult {
                    ZStack {
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
                                .background(Color.blue)
                                .clipShape(Capsule())
                            }
                            Spacer()
                        }
                        .padding(.leading, 20)
                        
                        HStack(spacing: 0) {
                            ForEach(CaptureMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue)
                                    .font(.system(size: 14, weight: captureMode == mode ? .bold : .medium))
                                    .foregroundColor(captureMode == mode ? .yellow : .white)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 16)
                                    .background(
                                        ZStack {
                                            if captureMode == mode {
                                                Capsule().fill(.thickMaterial)
                                                    .matchedGeometryEffect(id: "modeBackground", in: modeAnimation)
                                            }
                                        }
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            if !sessionManager.isRecording {
                                                captureMode = mode
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                    .frame(width: screenWidth)
                    .position(x: screenWidth / 2, y: screenHeight - 160)
                    .zIndex(60)
                }

                // 8. Bottom Controls
                if !showResult {
                    HStack(spacing: 24) {
                        Button(action: resetSession) {
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 24))
                                Text("RESET")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1)
                            }
                            .foregroundColor(sessionManager.isRecording ? .white.opacity(0.3) : .white.opacity(0.7))
                            .frame(width: 64, height: 64)
                        }
                        .disabled(sessionManager.isRecording)
                        
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
                            .shadow(color: Color.white.opacity(0.3), radius: 10, x: 0, y: 0)
                        }
                        .disabled(!sessionManager.isSessionReady || networkManager.serverStatus != .connected)
                        
                        Button(action: startProcessing) {
                            VStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                Text("CALC")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1)
                            }
                            .foregroundColor(localCapturedFrames.count >= 2 && !sessionManager.isRecording && !isProcessingLocally && networkManager.processStatus != .processing ? .white.opacity(0.7) : .white.opacity(0.3))
                            .frame(width: 64, height: 64)
                        }
                        .disabled(localCapturedFrames.count < 2 || networkManager.processStatus == .processing || isProcessingLocally || sessionManager.isRecording)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                    .position(x: screenWidth / 2, y: screenHeight - 80)
                    .zIndex(100)
                }
            }
        }
        .onAppear {
            sessionManager.startSession()
            Task { await networkManager.checkHealth() }
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
            if let color = color, color != .clear {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            if let icon = icon {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(.white.opacity(0.7))
            }
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.1))
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
    }
    
    @ViewBuilder
    private var feedbackText: some View {
        switch sessionManager.currentFeedback {
        case .ok: Text("천천히 움직여주세요")
        case .moveMore: Text("각도를 더 바꿔보세요")
        case .slowDown: Text("너무 빨라요!")
        case .trackingLost: Text("주변을 인식 중입니다...")
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
    
    // MARK: - Actions
    private func handleShutterAction() {
        if captureMode == .photo { manualCapture() } else { toggleRecording() }
    }

    private func toggleRecording() {
        if sessionManager.isRecording {
            sessionManager.isRecording = false
            print("녹화 종료. 총 프레임: \(localCapturedFrames.count)")
        } else {
            // 1. UI 즉시 반응 및 매핑 고정
            sessionManager.isRecording = true
            sessionManager.setWorldMapping(enabled: false)
            
            // 2. 첫 번째 프레임 즉시 캡처 (개수 표시 즉시 반영)
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
            guard sessionManager.isRecording else { timer.invalidate(); return }
            if let frame = sessionManager.currentFrame {
                let check = sessionManager.checkShouldCapture(frame: frame)
                DispatchQueue.main.async { sessionManager.currentFeedback = check.feedback }
                if check.shouldCapture {
                    if let (imageData, metadata) = sessionManager.capturePhoto() {
                        DispatchQueue.main.async {
                            localCapturedFrames.append((imageData, metadata))
                            sessionManager.recordCapturedFrame(transform: frame.camera.transform, time: frame.timestamp)
                            Task { try? await networkManager.uploadPhoto(imageData: imageData, metadata: metadata) }
                        }
                    }
                }
            }
        }
    }
    
    private func manualCapture() {
        guard let frame = sessionManager.currentFrame else { return }
        let check = sessionManager.checkShouldCapture(frame: frame)
        sessionManager.currentFeedback = check.feedback
        
        if localCapturedFrames.isEmpty { sessionManager.setWorldMapping(enabled: false) }

        if let (imageData, metadata) = sessionManager.capturePhoto() {
            isProcessingLocally = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isProcessingLocally = false }
            localCapturedFrames.append((imageData, metadata))
            sessionManager.recordCapturedFrame(transform: frame.camera.transform, time: frame.timestamp)
            Task {
                do {
                    if networkManager.sessionUUID == nil { _ = try await networkManager.registerSession() }
                    try await networkManager.uploadPhoto(imageData: imageData, metadata: metadata)
                } catch { print("사진 업로드 실패: \(error)") }
            }
        }
    }
    
    private func startProcessing() {
        Task {
            isProcessingLocally = true
            do {
                while networkManager.pendingUploadCount > 0 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    print("남은 전송 대기 중... (\(networkManager.pendingUploadCount))")
                }
                localCapturedFrames.removeAll()
                let volume = try await networkManager.processAndWaitForResult()
                
                await MainActor.run {
                    isProcessingLocally = false
                    if volume >= 100 {
                        targetMlValue = 100
                        Task { try? await networkManager.getFillHeight(targetMl: 100) }
                    } else if volume > 10 {
                        targetMlValue = volume / 2
                        Task { try? await networkManager.getFillHeight(targetMl: targetMlValue) }
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
        networkManager.cupBottomCenter = nil
        networkManager.fillLineCenter = nil
        networkManager.fillLineRadius = 0
        networkManager.processStatus = .idle
        networkManager.sessionUUID = nil
        sessionManager.setWorldMapping(enabled: true)
    }
}

// MARK: - ✨ Circular Camera-Style Dial Picker
struct CircularDialPicker: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onCommit: (() -> Void)? = nil
    
    @State private var lastDragValue: Double = 0
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    
    // 다이얼 설정
    private let radius: CGFloat = 180 // 화면에 맞게 크기 최적화
    private let valuePerTick: Double = 5.0 // 5ml 당 눈금 1개
    private let anglePerTick: Double = 3.0 // 눈금 1개당 3도
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. 볼륨 수치 표시 (상단 고정)
            VStack(spacing: -4) {
                Text("\(Int(value))")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundColor(.yellow)
                Text("ml")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.yellow.opacity(0.8))
            }
            .padding(.bottom, 20)
            
            GeometryReader { geometry in
                let midX = geometry.size.width / 2
                let topY: CGFloat = 20 // 아치형 다이얼의 최고점 y좌표
                
                ZStack {
                    // 2. 다이얼 눈금들 (화면에 보일 만큼만 동적 생성)
                    let centerTick = Int(value / valuePerTick)
                    let visibleTicks = 20 // 좌우로 그릴 눈금 개수
                    let startTick = max(Int(range.lowerBound / valuePerTick), centerTick - visibleTicks)
                    let endTick = min(Int(range.upperBound / valuePerTick), centerTick + visibleTicks)
                    
                    if startTick <= endTick {
                        ForEach(startTick...endTick, id: \.self) { i in
                            let tickValue = Double(i) * valuePerTick
                            // 현재 value 기준 상대적 각도 계산
                            let angleDiff = (tickValue - value) / valuePerTick * anglePerTick
                            
                            let isMainTick = i % 10 == 0 // 50ml 마다 큰 눈금
                            let isMediumTick = i % 2 == 0 // 10ml 마다 중간 눈금
                            
                            let width: CGFloat = isMainTick ? 2 : 1
                            let height: CGFloat = isMainTick ? 24 : (isMediumTick ? 14 : 8)
                            
                            let radians = angleDiff * .pi / 180
                            // 🌈 무지개 모양(^)으로 아치를 그립니다
                            let xPos = radius * sin(radians)
                            let yPos = radius * (1 - cos(radians))
                            
                            Rectangle()
                                .fill(isMainTick ? Color.white : Color.white.opacity(0.5))
                                .frame(width: width, height: height)
                                .rotationEffect(.degrees(angleDiff))
                                .position(x: midX + xPos, y: topY + yPos)
                                
                            // 큰 눈금 아래에 수치 표시
                            if isMainTick {
                                Text("\(Int(tickValue))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .rotationEffect(.degrees(angleDiff))
                                    .position(x: midX + (radius - 28) * sin(radians), 
                                              y: topY + radius - ((radius - 28) * cos(radians)))
                            }
                        }
                    }
                    
                    // 3. 중앙 포인터 (노란 삼각형)
                    Image(systemName: "arrowtriangle.down.fill")
                        .resizable()
                        .frame(width: 14, height: 10)
                        .foregroundColor(.yellow)
                        .position(x: midX, y: topY - 14)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            let delta = gesture.translation.width - lastDragValue
                            let sensitivity: Double = 0.4 // 드래그 감도
                            
                            // 드래그 방향에 맞춰 값 증감
                            let newValue = value - delta * sensitivity * valuePerTick
                            let clampedValue = max(range.lowerBound, min(range.upperBound, newValue))
                            
                            // 1단위 변화마다 햅틱
                            if Int(clampedValue) != Int(value) {
                                haptic.impactOccurred(intensity: 0.6)
                            }
                            
                            value = clampedValue
                            lastDragValue = gesture.translation.width
                        }
                        .onEnded { _ in
                            lastDragValue = 0
                            withAnimation(.easeOut(duration: 0.2)) {
                                value = round(value) // 스냅 효과
                            }
                            // 손가락을 뗐을 때 콜백 실행
                            onCommit?()
                        }
                )
                // 좌우 끝으로 갈수록 자연스럽게 페이드아웃
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.3),
                            .init(color: .black, location: 0.7),
                            .init(color: .clear, location: 1.0)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
        }
    }
}
