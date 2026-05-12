//
//  ARCameraView.swift
//  pour
//
//  ARKit Camera View for SwiftUI
//

import SwiftUI
import ARKit
import SceneKit

struct ARCameraView: UIViewRepresentable {
    @ObservedObject var sessionManager: ARSessionManager
    var cupBottomCenter: [Float]?  // [x, y, z] ARKit world coordinates
    var fillLineCenter: [Float]?   // [x, y, z] ARKit world coordinates
    var fillLineRadius: Float?     // Radius for ring drawing
    var targetMl: Double?          // [Added] Display volume in mL
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session = sessionManager.session
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = true
        
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // --- Cup Bottom Marker ---
        let existingMarker = uiView.scene.rootNode.childNode(withName: "cupBottomMarker", recursively: false)
        
        if let center = cupBottomCenter, center.count == 3 {
            if existingMarker == nil {
                let sphere = SCNSphere(radius: 0.01)
                sphere.firstMaterial?.diffuse.contents = UIColor.systemGreen
                sphere.firstMaterial?.emission.contents = UIColor.green.withAlphaComponent(0.3)
                
                let sphereNode = SCNNode(geometry: sphere)
                sphereNode.name = "cupBottomMarker"
                sphereNode.position = SCNVector3(center[0], center[1], center[2])
                
                let pulseAction = SCNAction.sequence([
                    SCNAction.scale(to: 1.2, duration: 0.5),
                    SCNAction.scale(to: 1.0, duration: 0.5)
                ])
                sphereNode.runAction(SCNAction.repeatForever(pulseAction))
                
                uiView.scene.rootNode.addChildNode(sphereNode)
                print("Added bottom marker at: \(center[0]), \(center[1]), \(center[2])")
            }
        } else {
            existingMarker?.removeFromParentNode()
        }
        
        // --- Fill Line Ring & Volume Text ---
        let existingRing = uiView.scene.rootNode.childNode(withName: "fillLineRing", recursively: false)
        let existingText = uiView.scene.rootNode.childNode(withName: "fillLineText", recursively: false)
        
        if let center = fillLineCenter, center.count == 3, let radius = fillLineRadius, radius > 0 {
            // Always update position
            existingRing?.removeFromParentNode()
            existingText?.removeFromParentNode()
            
            // 1. Create torus (ring)
            let torus = SCNTorus(ringRadius: CGFloat(radius), pipeRadius: 0.0015)
            torus.firstMaterial?.diffuse.contents = UIColor.systemOrange
            torus.firstMaterial?.emission.contents = UIColor.orange.withAlphaComponent(0.5)
            
            let ringNode = SCNNode(geometry: torus)
            ringNode.name = "fillLineRing"
            ringNode.position = SCNVector3(center[0], center[1], center[2])
            ringNode.eulerAngles = SCNVector3(0, Float.pi / 2, 0)
            
            // Pulsing animation
            let pulseAction = SCNAction.sequence([
                SCNAction.scale(to: 1.1, duration: 0.4),
                SCNAction.scale(to: 1.0, duration: 0.4)
            ])
            ringNode.runAction(SCNAction.repeatForever(pulseAction))
            uiView.scene.rootNode.addChildNode(ringNode)
            
            // 2. Create Volume Text Node
            if let ml = targetMl {
                let textGeo = SCNText(string: "\(Int(ml))ml", extrusionDepth: 0.01)
                textGeo.font = UIFont.systemFont(ofSize: 1.0, weight: .bold)
                textGeo.firstMaterial?.diffuse.contents = UIColor.white
                
                let textNode = SCNNode(geometry: textGeo)
                textNode.name = "fillLineText"
                
                // Scale text to appropriate size
                textNode.scale = SCNVector3(0.015, 0.015, 0.015)
                
                // Position: Centered above the ring or slightly to the side
                // Offsetting x slightly to account for text width
                textNode.position = SCNVector3(center[0] + radius + 0.01, center[1] + 0.01, center[2])
                
                // Make text always face the user
                let constraint = SCNBillboardConstraint()
                constraint.freeAxes = .all
                textNode.constraints = [constraint]
                
                uiView.scene.rootNode.addChildNode(textNode)
            }
            
            print("Added fill ring and text at: \(center[0]), \(center[1]), \(center[2])")
        } else {
            existingRing?.removeFromParentNode()
            existingText?.removeFromParentNode()
        }
    }
}

#Preview {
    ARCameraView(sessionManager: ARSessionManager())
}
