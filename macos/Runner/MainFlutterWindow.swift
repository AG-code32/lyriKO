import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let audioRecognizer = LyrikoMacAudioRecognizer()
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    audioRecognizer.install(on: flutterViewController)

    super.awakeFromNib()
  }
}
