//
//  ARScanViewController.swift
//  ScannAR
//
//  Created by Joshua Kaunert on 3/20/19.
//  Copyright © 2019 ScannAR Team. All rights reserved.
//

import UIKit
import SceneKit
import ARKit

class ARScanViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate, UIDocumentPickerDelegate {
    
    static let appStateChangedNotification = Notification.Name("ApplicationStateChanged")
    static let appStateUserInfoKey = "AppState"
    
    static var instance: ARScanViewController?
    
    @IBOutlet weak var sceneView: ARSCNView!
    @IBOutlet weak var blurView: UIVisualEffectView!
    @IBOutlet weak var nextButton: RoundedButton!
    var backButton: UIBarButtonItem!
 
    @IBOutlet weak var instructionView: UIVisualEffectView!
    @IBOutlet weak var instructionLabel: MessageLabel!
    @IBOutlet weak var loadModelButton: RoundedButton!
    @IBOutlet weak var flashlightButton: RoundedButton!
    @IBOutlet weak var navigationBar: UINavigationBar!
    @IBOutlet weak var sessionInfoView: UIVisualEffectView!
    @IBOutlet weak var sessionInfoLabel: UILabel!
    @IBOutlet weak var toggleInstructionsButton: FlashlightButton!
    
    internal var internalState: State = .startARSession
    
    internal var scan: ARScan?
    
    var referenceObjectToMerge: ARReferenceObject?
    var referenceObjectToTest: ARReferenceObject?
    
    internal var testRun: ARObjectDetectTestController?
    
    internal var messageExpirationTimer: Timer?
    internal var startTimeOfLastMessage: TimeInterval?
    internal var expirationTimeOfLastMessage: TimeInterval?
    
    internal var screenCenter = CGPoint()
    
    var modelURL: URL? {
        didSet {
            if let url = modelURL {
                displayMessage("3D model \"\(url.lastPathComponent)\" received.", expirationTime: 3.0)
            }
            if let scannedObject = self.scan?.scannedObject {
                scannedObject.set3DModel(modelURL)
            }
            if let dectectedObject = self.testRun?.detectedObject {
                dectectedObject.set3DModel(modelURL)
            }
        }
    }
    
    var instructionsVisible: Bool = true {
        didSet {
            instructionView.isHidden = !instructionsVisible
            toggleInstructionsButton.toggledOn = instructionsVisible
        }
    }
    
    // MARK: - Application Lifecycle
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ARScanViewController.instance = self
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        
        sceneView.delegate = self
        sceneView.session.delegate = self
        
        // Prevent the screen from being dimmed after a while.
        UIApplication.shared.isIdleTimerDisabled = true
        
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(scanningStateChanged), name: ARScan.stateChangedNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(ghostBoundingBoxWasCreated),
                                       name: ScannedObject.ghostBoundingBoxCreatedNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(ghostBoundingBoxWasRemoved),
                                       name: ScannedObject.ghostBoundingBoxRemovedNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(boundingBoxWasCreated),
                                       name: ScannedObject.boundingBoxCreatedNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(scanPercentageChanged),
                                       name: BoundingBox.scanPercentageChangedNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(boundingBoxPositionOrExtentChanged(_:)),
                                       name: BoundingBox.extentChangedNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(boundingBoxPositionOrExtentChanged(_:)),
                                       name: BoundingBox.positionChangedNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(objectOriginPositionChanged(_:)),
                                       name: ObjectOrigin.positionChangedNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(displayWarningIfInLowPowerMode),
                                       name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        
        setupNavigationBar()
        
        displayWarningIfInLowPowerMode()
        
        // Make sure the application launches in .startARSession state.
        // Entering this state will run() the ARSession.
        state = .startARSession
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Store the screen center location after the view's bounds did change,
        // so it can be retrieved later from outside the main thread.
        screenCenter = sceneView.center
    }
    
    // MARK: - UI Event Handling
    
    @IBAction func restartButtonTapped(_ sender: Any) {
        if let scan = scan, scan.boundingBoxExists {
            let title = "Start over?"
            let message = "Discard the current scan and start over?"
            self.showAlert(title: title, message: message, buttonTitle: "Yes", showCancel: true) { _ in
                self.state = .startARSession
            }
        } else if testRun != nil {
            let title = "Start over?"
            let message = "Discard this scan and start over?"
            self.showAlert(title: title, message: message, buttonTitle: "Yes", showCancel: true) { _ in
                self.state = .startARSession
            }
        } else {
            self.state = .startARSession
        }
    }
    
    func backFromBackground() {
        if state == .scanning {
            let title = "Warning: Scan may be broken"
            let message = "The scan was interrupted. It is recommended to restart the scan."
            let buttonTitle = "Restart Scan"
            self.showAlert(title: title, message: message, buttonTitle: buttonTitle, showCancel: true) { _ in
                self.state = .notReady
            }
        }
    }
    
    @IBAction func previousButtonTapped(_ sender: Any) {
        switchToPreviousState()
    }
    
    @IBAction func nextButtonTapped(_ sender: Any) {
        guard !nextButton.isHidden && nextButton.isEnabled else { return }
        switchToNextState()
    }
    
  
    
    @IBAction func leftButtonTouchAreaTapped(_ sender: Any) {
        
       
        // A tap in the extended hit area on the lower left should cause a tap
        //  on the button that is currently visible at that location.
        if !flashlightButton.isHidden {
            toggleFlashlightButtonTapped(self)
        }
    }
    
    @IBAction func toggleFlashlightButtonTapped(_ sender: Any) {
        guard !flashlightButton.isHidden && flashlightButton.isEnabled else { return }
        flashlightButton.toggledOn = !flashlightButton.toggledOn
    }
    
    @IBAction func toggleInstructionsButtonTapped(_ sender: Any) {
        guard !toggleInstructionsButton.isHidden && toggleInstructionsButton.isEnabled else { return }
        instructionsVisible.toggle()
    }
    
    func displayInstruction(_ message: Message) {
        instructionLabel.display(message)
        instructionsVisible = true
    }
    
    func showAlert(title: String, message: String, buttonTitle: String? = "OK", showCancel: Bool = false, buttonHandler: ((UIAlertAction) -> Void)? = nil) {
        print(title + "\n" + message)
        
        var actions = [UIAlertAction]()
        if let buttonTitle = buttonTitle {
            actions.append(UIAlertAction(title: buttonTitle, style: .default, handler: buttonHandler))
        }
        if showCancel {
            actions.append(UIAlertAction(title: "Cancel", style: .cancel))
        }
        self.showAlert(title: title, message: message, actions: actions)
    }
    
    func showAlert(title: String, message: String, actions: [UIAlertAction]) {
        let showAlertBlock = {
            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
            actions.forEach { alertController.addAction($0) }
            DispatchQueue.main.async {
                self.present(alertController, animated: true, completion: nil)
            }
        }
        
        if presentedViewController != nil {
            dismiss(animated: true) {
                showAlertBlock()
            }
        } else {
            showAlertBlock()
        }
    }
    
    func testObjectDetection() {
        // In case an object for testing has been received, use it right away...
        if let object = referenceObjectToTest {
            testObjectDetection(of: object)
            return
        }
        
        // ...otherwise attempt to create a reference object from the current scan.
        guard let scan = scan, scan.boundingBoxExists else {
            print("Error: Bounding box not yet created.")
            return
        }
        
        scan.createReferenceObject { scannedObject in
            if let object = scannedObject {
                self.testObjectDetection(of: object)
            } else {
                let title = "Scan failed"
                let message = "Saving the scan failed."
                let buttonTitle = "Restart Scan"
                self.showAlert(title: title, message: message, buttonTitle: buttonTitle, showCancel: false) { _ in
                    self.state = .startARSession
                }
            }
        }
    }
    
    func testObjectDetection(of object: ARReferenceObject) {
        self.testRun?.setReferenceObject(object, screenshot: scan?.screenshot)
        
        // Delete the scan to make sure that users cannot go back from
        // testing to scanning, because:
        // 1. Testing and scanning require running the ARSession with different configurations,
        //    thus the scanned environment is lost when starting a test.
        // 2. We encourage users to move the scanned object during testing, which invalidates
        //    the feature point cloud which was captured during scanning.
        self.scan = nil
        self.displayInstruction(Message("""
                    Test detection of the object from different angles. Consider moving the object to different environments and test there.
                    """))
    }
    
    func createAndShareReferenceObject() {
        
        guard let testRun = self.testRun,
            let object = testRun.referenceObject else {
                print("Error: Missing scanned object.")
                return
        }
        DispatchQueue.global().async {
            do {
                let documentDirectory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor:nil, create:false)
                
                let alert = UIAlertController(title: "Enter object Name", message: "", preferredStyle: .alert)
                alert.addTextField { (textField) in
                    textField.placeholder = "Please Enter object Name"
                }
                alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak alert] (_) in
                    let textField = alert?.textFields![0] // Force unwrapping because we know it exists.
                    print("Text field: \((textField?.text)!)")
                    let documentURL = documentDirectory.appendingPathComponent((textField?.text)! + ".\(SavedARScansListViewController.kArObject)")
                    DispatchQueue.global().async {
                        do {
                            try object.export(to: documentURL, previewImage: testRun.previewImage)
                        } catch {
                            fatalError("Failed to save the file to \(documentURL)")
                        }
                        DispatchQueue.main.async {
                            self.navigationController?.popViewController(animated: true)
                        }
                    }
                }))
                DispatchQueue.main.async {
                    self.present(alert, animated: true, completion: nil)
                }
                
            } catch {
                print(error)
            }
        }
    }
    
    var limitedTrackingTimer: Timer?
    
    func startLimitedTrackingTimer() {
        guard limitedTrackingTimer == nil else { return }
        
        limitedTrackingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            self.cancelLimitedTrackingTimer()
            guard let scan = self.scan else { return }
            if scan.state == .defineBoundingBox || scan.state == .scanning || scan.state == .adjustingOrigin {
                let title = "Limited Tracking"
                let message = "Low tracking quality - it is unlikely that a good reference object can be generated from this scan."
                let buttonTitle = "Restart Scan"
                
                self.showAlert(title: title, message: message, buttonTitle: buttonTitle, showCancel: true) { _ in
                    self.state = .startARSession
                }
            }
        }
    }
    
    func cancelLimitedTrackingTimer() {
        limitedTrackingTimer?.invalidate()
        limitedTrackingTimer = nil
    }
    
    var maxScanTimeTimer: Timer?
    
    func startMaxScanTimeTimer() {
        guard maxScanTimeTimer == nil else { return }
        
        let timeout: TimeInterval = 60.0 * 5
        
        maxScanTimeTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            self.cancelMaxScanTimeTimer()
            guard self.state == .scanning else { return }
            let title = "Scan is taking too long"
            let message = "Scanning consumes a lot of resources. This scan has been running for \(Int(timeout)) s. Consider closing the app and letting the device rest for a few minutes."
            let buttonTitle = "OK"
            self.showAlert(title: title, message: message, buttonTitle: buttonTitle, showCancel: true)
        }
    }
    
    func cancelMaxScanTimeTimer() {
        maxScanTimeTimer?.invalidate()
        maxScanTimeTimer = nil
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        
        updateSessionInfoLabel(for: camera.trackingState)
        
        switch camera.trackingState {
        case .notAvailable:
            state = .notReady
        case .limited(let reason):
            switch state {
            case .startARSession:
                state = .notReady
            case .notReady, .testing:
                break
            case .scanning:
                if let scan = scan {
                    switch scan.state {
                    case .ready:
                        state = .notReady
                    case .defineBoundingBox, .scanning, .adjustingOrigin:
                        if reason == .relocalizing {
                            // If ARKit is relocalizing we should abort the current scan
                            // as this can cause unpredictable distortions of the map.
                            print("Warning: ARKit is relocalizing")
                            
                            let title = "Warning: Scan may be broken"
                            let message = "A gap in tracking has occurred. It is recommended to restart the scan."
                            let buttonTitle = "Restart Scan"
                            self.showAlert(title: title, message: message, buttonTitle: buttonTitle, showCancel: true) { _ in
                                self.state = .notReady
                            }
                            
                        } else {
                            // Suggest the user to restart tracking after a while.
                            startLimitedTrackingTimer()
                        }
                    }
                }
            }
        case .normal:
            if limitedTrackingTimer != nil {
                cancelLimitedTrackingTimer()
            }
            
            switch state {
            case .startARSession, .notReady:
                state = .scanning
            case .scanning, .testing:
                break
            }
        }
    }
    
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let frame = sceneView.session.currentFrame else { return }
        scan?.updateOnEveryFrame(frame)
        testRun?.updateOnEveryFrame()
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        if let objectAnchor = anchor as? ARObjectAnchor {
            if let testRun = self.testRun, objectAnchor.referenceObject == testRun.referenceObject {
                testRun.successfulDetection(objectAnchor)
                let messageText = """
                    Object successfully detected from this angle.

                    """ + testRun.statistics
                displayMessage(messageText, expirationTime: testRun.resultDisplayDuration)
            }
        } else if state == .scanning, let planeAnchor = anchor as? ARPlaneAnchor {
            scan?.scannedObject.tryToAlignWithPlanes([planeAnchor])
            
            // After a plane was found, disable plane detection for performance reasons.
            sceneView.stopPlaneDetection()
        }
    }
    
   
    @objc
    func scanPercentageChanged(_ notification: Notification) {
        guard let percentage = notification.userInfo?[BoundingBox.scanPercentageUserInfoKey] as? Int else { return }
        
        // Switch to the next state if the scan is complete.
        if percentage >= 100 {
            switchToNextState()
            return
        }
        DispatchQueue.main.async {
            self.setNavigationBarTitle("Scan (\(percentage)%)")
        }
    }
    
    @objc
    func boundingBoxPositionOrExtentChanged(_ notification: Notification) {
        guard let box = notification.object as? BoundingBox,
            let cameraPos = sceneView.pointOfView?.simdWorldPosition else { return }
        
        // FIXME: - make an extension for the maths. Also in DetectedBoundingBox
        let xString = String(format: "length: %.2f", box.extent.x * 39.3701)
        let yString = String(format: "height: %.2f", box.extent.y * 39.3701)
        let zString = String(format: "width: %.2f", box.extent.z * 39.3701)
        let distanceFromCamera = String(format: "%.2f in", distance(box.simdWorldPosition, cameraPos) * 39.3701)
        displayMessage("Current bounding box: \(distanceFromCamera) away\n\(xString) \(yString) \(zString)", expirationTime: 1.5)
    }
    
    @objc
    func objectOriginPositionChanged(_ notification: Notification) {
        guard let node = notification.object as? ObjectOrigin else { return }
        
        // Display origin position w.r.t. bounding box
        let xString = String(format: "x: %.2f", node.position.x)
        let yString = String(format: "y: %.2f", node.position.y)
        let zString = String(format: "z: %.2f", node.position.z)
        displayMessage("Current local origin position in meters:\n\(xString) \(yString) \(zString)", expirationTime: 1.5)
    }
    
    @objc
    func displayWarningIfInLowPowerMode() {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            let title = "Low Power Mode is enabled"
            let message = "Performance may be impacted. For best scanning results, disable Low Power Mode in Settings > Battery, and restart the scan."
            let buttonTitle = "OK"
            self.showAlert(title: title, message: message, buttonTitle: buttonTitle, showCancel: false)
        }
    }
    
    override var shouldAutorotate: Bool {
        // Lock UI rotation after starting a scan
        if let scan = scan, scan.state != .ready {
            return false
        }
        return true
    }
}
