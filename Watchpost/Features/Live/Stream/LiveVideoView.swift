import AVFoundation
import SwiftUI
import UIKit

/// Shows a live stream's video layer, with no system controls on top.
///
/// A layer can only be in one place, so when full screen opens it takes the layer, and when
/// it closes the layer goes back to the card it came from.
struct LiveVideoView: UIViewRepresentable {
    let stream: LiveStream
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> LiveVideoHostView {
        let view = LiveVideoHostView()
        view.backgroundColor = .clear
        view.gravity = gravity
        stream.attach(to: view)
        return view
    }

    func updateUIView(_ view: LiveVideoHostView, context: Context) {
        view.gravity = gravity
    }

    static func dismantleUIView(_ view: LiveVideoHostView, coordinator: ()) {
        view.stream?.detach(from: view)
    }
}

/// Hosts the video layer in a zooming scroll view: pinch to zoom, drag to pan while zoomed,
/// double-tap to zoom in on a spot or back out. Unzoomed, it doesn't scroll, so the page
/// around it still does.
final class LiveVideoHostView: UIView, UIScrollViewDelegate {
    weak var stream: LiveStream?
    var gravity: AVLayerVideoGravity = .resizeAspectFill {
        didSet { if hostsLayer { stream?.displayLayer.videoGravity = gravity } }
    }

    private let scrollView = UIScrollView()
    /// The layer's parent; the scroll view scales it.
    let videoView = UIView()

    var hostsLayer: Bool { stream?.displayLayer.superlayer === videoView.layer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        addSubview(scrollView)
        scrollView.addSubview(videoView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if scrollView.zoomScale == 1 {
            videoView.frame = bounds
            scrollView.contentSize = bounds.size
        }
        guard hostsLayer, let displayLayer = stream?.displayLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = videoView.bounds
        CATransaction.commit()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { videoView }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: videoView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            scrollView.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
        }
    }
}

extension LiveStream {
    @MainActor
    func attach(to view: LiveVideoHostView) {
        view.stream = self
        hostViews.append(WeakHostView(view: view))
        show(in: view)
    }

    @MainActor
    func detach(from view: LiveVideoHostView) {
        hostViews.removeAll { $0.view == nil || $0.view === view }
        if view.hostsLayer, let previous = hostViews.last?.view {
            show(in: previous)
        }
    }

    @MainActor
    private func show(in view: LiveVideoHostView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.removeFromSuperlayer()
        displayLayer.videoGravity = view.gravity
        displayLayer.frame = view.videoView.bounds
        view.videoView.layer.addSublayer(displayLayer)
        CATransaction.commit()
    }
}

struct WeakHostView {
    weak var view: LiveVideoHostView?
}
