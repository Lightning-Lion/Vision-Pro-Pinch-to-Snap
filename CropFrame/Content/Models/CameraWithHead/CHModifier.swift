import os
import SwiftUI
import RealityKit
import VisionProKit

// 功能性Modifier
struct CameraWithHeadModifier: ViewModifier {
    @State
    var model:CameraWithHead
    let baseEntity:Entity
    func body(content: Content) -> some View {
        content
            .onDisappear {
                // 正确释放资源
                os_log("释放CameraWithHead的资源")
                model.task?.cancel()
            }
            .modifier(CameraWithHeadShowError(errorMessage: model.error?.localizedDescription, baseEntity: baseEntity))
    }
}

// 弹窗显示出错
fileprivate
struct CameraWithHeadShowError: ViewModifier {
    var errorMessage:String?
    let baseEntity:Entity
    @State
    private var container:Entity? = nil
    func body(content: Content) -> some View {
        content
            .onChange(of: errorMessage, initial: true) { oldValue, newValue in
                if let newValue {
                    os_log("触发错误弹窗")
                    showPopup(errorMessage: newValue)
                } else {
                    // 先前有错误弹窗，则关闭
                    if oldValue != nil {
                        os_log("关闭错误弹窗")
                        container?.removeFromParent()
                        container = nil
                    }
                }
            }
    }
    private
    func showPopup(errorMessage:String) {
        let window = Entity()
        window.components.set(ViewAttachmentComponent(rootView: CameraWithHeadErrorView(error: errorMessage)))
        window.components.set(BillboardComponent())
        let head = AnchorEntity(.head)
        head.addChild(window)
        // 面前偏下，舒适的阅读位置，伸伸手也能触摸到
        window.position = [0,-0.1,-0.55]
        let container = Entity()
        self.container = container
        container.addChild(head)
        baseEntity.addChild(container)
    }
}
