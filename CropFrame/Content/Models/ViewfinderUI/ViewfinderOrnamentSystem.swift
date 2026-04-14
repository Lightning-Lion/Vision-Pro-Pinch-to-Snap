import os
import Combine
import SwiftUI
import RealityKit
import VisionProKit

// Ornament就是只管外观与瞄准
// 用户触发了点击手势会外传，让使用者处理
@MainActor
@Observable
class ViewfinderOrnamentSystem {
    var error:Error? = nil
    fileprivate var vm = ViewfinderSystemModel()
    fileprivate var headMod = HeadAxisModel()
    private var viewfinderControlPointModel = HandControlPointModel()
    private var clickableSkyBoxMod = ClickableSkyBoxModel()
    func mount(baseEntity:Entity,dismissImmersiveSpace:DismissImmersiveSpaceAction,onShutterGesture:@escaping (ViewfinderPoseModel.ViewfinderOrnamentPose,ViewfinderOrnamentPoseToCornersPose.ViewfinderOrnamentCornersPose) -> ()) async {
        var authOK = false
        do {
            // 先申请权限，不然进入ImmersiveSpace也无法正常工作
            try await requestHandAndCameraAuthorization()
            authOK = true
        } catch {
            // 先申请权限，不然进入ImmersiveSpace也无法正常工作
            await dismissImmersiveSpace()
            onAuthorizationError.send(error)
        }
        // 权限已申请成功，可以继续，否则返回（错误提示会显示在WindowGroup）
        guard authOK else {
            return
        }
        do {
            // 创建一个巨大的透明球体来包裹用户
            let skyBox = clickableSkyBoxMod.clickableSkyBox()
            let head = AnchorEntity(.head)
            head.addChild(skyBox)
            baseEntity.addChild(head)
            // 创建取景框
            let newViewfinder:Entity = buildViewfindEntity(controller: vm.controller.viewController)
            vm.controller.entity = newViewfinder
            baseEntity.addChild(newViewfinder)
            try await headMod.run()
            // 启动手检测
            await viewfinderControlPointModel.run(baseEntity: baseEntity)
            vm.run(headMod: headMod, viewfinderControlPointModel: viewfinderControlPointModel, baseEntity: baseEntity)
            // 设置双指捏合手势
            Task { @MainActor in
                do {
                    // 要等待baseEntity进入场景，才能设置订阅
                    // 这个过程应该很快，用不了几秒，轮询一下好了
                    let scene = try await getScene(baseEntity: baseEntity)
                    // 设置订阅
                    vm.token = scene.subscribe(to: ManipulationEvents.WillRelease.self)  { event in
                        // 使用者可能会在场景中添加其它Entity
                        // 校验我关心的Entity
                        // 只响应对于无限远天空的咔嚓手势
                        // 还可以检查事件，少于几百毫秒才算作「点击」手势（而不是长按/拖动）
                        if self.clickableSkyBoxMod.isClickGesture(event: event) {
                            os_log("触发了快门手势")
                            self.vm.soundTrigger = UUID()
                            do {
                                let (pose,cornersPose) = try self.vm.controller.getPoseAndCornersPose()
                                onShutterGesture(pose,cornersPose)
                            } catch {
                                self.error = error
                            }
                        }
                    }
                    os_log("已成功设置订阅")
                } catch {
                    os_log("订阅失败")
                    os_log("\(error.localizedDescription)")
                }
            }
        } catch {
            // 启动阶段的错误，直接中止启动，向外报
            await dismissImmersiveSpace()
            onStartingViewfinderSystemError.send(error)
        }
    }
    
    // 因为传入的是Entity，而我们需要在RealityViewContent或者RealityKit.Scene上才能.subscribe(
    private
    func getScene(baseEntity:Entity) async throws -> RealityKit.Scene {
        while true {
            if let scene:RealityKit.Scene = baseEntity.scene {
                return scene
                // 循环结束
            } else {
                // 下一帧再试试
                try await Task.sleep(for: .seconds(1/120))
            }
        }
    }
}

struct ViewfinderSystemModifier: ViewModifier {
    @State
    var system:ViewfinderOrnamentSystem
    var baseEntity:Entity
    private var vm:ViewfinderSystemModel {
        system.vm
    }
    func body(content: Content) -> some View {
        content
            // 呈现多个组件各自的运行时错误
            .modifier(RuntimeError(errorMessage: system.error?.localizedDescription, baseEntity: baseEntity))
            .modifier(RuntimeError(errorMessage: vm.error?.localizedDescription, delay: 0.5/*允许500毫秒的手跟踪丢失*/, baseEntity: baseEntity))
            .onChange(of: vm.controller.pose, initial: true, { oldValue, newValue in
                vm.onViewfinderStateChange(baseEntity: baseEntity)
            })
            .modifier(ShutterSoundSupport(shutterTrigger: vm.soundTrigger))
            .onDisappear {
                // 正确释放资源
                os_log("释放ViewfinderSystemModel的资源")
                vm.tasks.forEach { $0.cancel() }
            }
    }
}

@MainActor
@Observable
fileprivate class ViewfinderSystemModel {
    
    var error:Error? = nil
    
    var tasks:[Task<Void,Never>] = []
    
    var soundTrigger = UUID()
    
    var token: Cancellable? = nil
    
    var controller:ViewfinderOrnamentController = ViewfinderOrnamentController()
    
    private var viewfinderController:ViewfinderViewController {
        controller.viewController
    }
    
    func run(headMod:HeadAxisModel,
             viewfinderControlPointModel:HandControlPointModel,baseEntity:Entity) {
        let task = Task { @MainActor in
            do {
                // 120FPS
                while true {
                    updateViewfinderState(headMod: headMod, viewfinderControlPointModel: viewfinderControlPointModel,baseEntity:baseEntity)
                    try await Task.sleep(for: .seconds(1/120))
                }
            } catch {
                os_log("ImmersiveSpace已关闭")
            }
        }
        tasks.append(task)
    }
    
    func onViewfinderStateChange(baseEntity:Entity) {
        // 使用controller进行更新
        guard let viewfinderState = controller.pose else {
            // 追踪丢失
            viewfinderController.show = false
            // 当show为false时，宽高、transform没有意义
            return
        }
        guard let viewfinder = controller.entity else {
            fatalError("调用顺序出错")
        }
        viewfinder.setTransformMatrix(viewfinderState.transform.matrix, relativeTo: baseEntity)
        viewfinderController.width = Float(viewfinderState.size.width)
        viewfinderController.height = Float(viewfinderState.size.height)
        viewfinderController.show = true
    }
    
    // 每帧更新取景框的状态（姿态和尺寸）
    private
    func updateViewfinderState(headMod:HeadAxisModel, viewfinderControlPointModel:HandControlPointModel, baseEntity:Entity) {
        var newError:Error? = nil
        do {
            controller.pose = try getViewfinderState(headMod: headMod, viewfinderControlPointModel: viewfinderControlPointModel,baseEntity: baseEntity)
        } catch {
            // 跟踪丢失要设为nil
            // func onViewfinderStateChange(viewfinderController:ViewfinderViewController,viewfinderEntity:Entity?,baseEntity:Entity) {
            // 会通知viewfinderController.show = false
            // 以做淡化消失
            controller.pose = nil
            newError = error
        }
        // 没有错误则清除，有错误则显示
        self.error = newError
    }
    
    // 计算取景框的状态（姿态和尺寸）
    private
    func getViewfinderState(headMod:HeadAxisModel, viewfinderControlPointModel:HandControlPointModel, baseEntity:Entity) throws -> ViewfinderPoseModel.ViewfinderOrnamentPose {
        guard let (leftWorld,rightWorld) = viewfinderControlPointModel.getControlPoint(baseEntity: baseEntity) else {
            logWithInterval("手没有准备好",tag:"a8c3902997b94d57a20a")
            throw GetViewfinderStateError.hand
        }
        guard let head:Transform = headMod.getHeadTransform() else {
            logWithInterval("头没有准备好",tag: "acf441eff7894fb0a5ca")
            throw GetViewfinderStateError.head
        }
        // 顺序无关，内部还会排序的
        let irrelevantOrder:Bool = Bool.random()
        let hand1ControlPointWorld = irrelevantOrder ? leftWorld : rightWorld
        let hand2ControlPointWorld = irrelevantOrder ? rightWorld : leftWorld
        do {
            let viewfinderWorld: ViewfinderPoseModel.ViewfinderOrnamentPose = try ViewfinderPoseModel().getViewfinderPose(hand1ControlPointWorld: hand1ControlPointWorld, hand2ControlPointWorld: hand2ControlPointWorld, head: head)
            return viewfinderWorld
        } catch {
            logWithInterval(error.localizedDescription, tag: "be019ae558674a04a775")
            throw GetViewfinderStateError.compute
        }
    }
    enum GetViewfinderStateError:LocalizedError {
        case hand
        case head
        case compute
        var errorDescription: String? {
            switch self {
            case .hand:
                "手跟踪未就绪"
            case .head:
                "头跟踪未就绪"
            case .compute:
                "计算取景框姿态和尺寸失败"
            }
        }
    }
}

@MainActor
@Observable
fileprivate class ViewfinderOrnamentController {
    // 取景框实体
    var entity:Entity? = nil
    // 取景框姿态
    var pose:ViewfinderPoseModel.ViewfinderOrnamentPose? = nil
    // 取景框控制器（我直接和View接触）
    var viewController = ViewfinderViewController()
    // 得到pose、cornersPose
    func getPoseAndCornersPose() throws -> (ViewfinderPoseModel.ViewfinderOrnamentPose,ViewfinderOrnamentPoseToCornersPose.ViewfinderOrnamentCornersPose) {
        guard let pose else {
            throw GetPoseError.invalidPose
        }
        let cornersPose = try getCornersPose()
        return (pose,cornersPose)
    }
    // 得到角点位置
    private func getCornersPose() throws -> ViewfinderOrnamentPoseToCornersPose.ViewfinderOrnamentCornersPose {
        guard let pose else {
            throw ViewfinderOrnamentPoseToCornersPose.GetCornerPoseError.invalidPose
        }
        return try ViewfinderOrnamentPoseToCornersPose().getCornersPose(from: pose)
    }
    enum GetPoseError:LocalizedError {
        case invalidPose
        var errorDescription: String? {
            switch self {
            case .invalidPose:
                "取景框不可见"
            }
        }
    }
}

@MainActor
@Observable
class ViewfinderOrnamentPoseToCornersPose {
    typealias ViewfinderOrnamentPose = ViewfinderPoseModel.ViewfinderOrnamentPose
    // 回传给使用者，使用者会将这几个角点投影到摄像头画面，并裁切出对应的区域
    // 复用VisionProKit中的定义，确保类型一致
    typealias ViewfinderOrnamentCornersPose = ThreeDTo2DProjector.ViewfinderOrnamentCornersPose
    
    enum GetCornerPoseError: LocalizedError {
        case invalidPose
        case calculationFailed
        var errorDescription: String? {
            switch self {
            case .invalidPose:
                "取景框不可见"
            case .calculationFailed:
                "计算失败"
            }
        }
    }

    func getCornersPose(from pose: ViewfinderOrnamentPose) throws -> ViewfinderOrnamentCornersPose {
        let transform = pose.transform
        let size = pose.size
        
        // 计算四个角点在局部坐标系中的位置（以中心为原点）
        // 假设size的width和height是矩形的实际尺寸，原点在中心
        let halfWidth = Float(size.width) / 2.0
        let halfHeight = Float(size.height) / 2.0
        
        // 四个角点在局部坐标系中的位置
        let localCorners: [SIMD3<Float>] = [
            SIMD3<Float>(-halfWidth, halfHeight, 0),    // top-left
            SIMD3<Float>(halfWidth, halfHeight, 0),     // top-right
            SIMD3<Float>(-halfWidth, -halfHeight, 0),   // bottom-left
            SIMD3<Float>(halfWidth, -halfHeight, 0)     // bottom-right
        ]
        
        // 使用Transform的矩阵将局部坐标变换到世界坐标
        let matrix = transform.matrix
        
        // 变换四个角点
        let worldCorners = localCorners.map { localPoint -> SIMD3<Float> in
            // 将局部点转换为齐次坐标
            let localHomogeneous = SIMD4<Float>(localPoint.x, localPoint.y, localPoint.z, 1.0)
            
            // 应用变换矩阵
            let worldHomogeneous = matrix * localHomogeneous
            
            // 返回3D坐标（忽略齐次坐标的w分量）
            return SIMD3<Float>(worldHomogeneous.x, worldHomogeneous.y, worldHomogeneous.z)
        }
        
        // 将SIMD3<Float>转换为Point3D
        func simdToPoint3D(_ simd: SIMD3<Float>) -> Point3D {
            // 由于Point3D使用Double，需要进行类型转换
            return Point3D(x: Double(simd.x), y: Double(simd.y), z: Double(simd.z))
        }
        
        // 创建并返回结果
        return ViewfinderOrnamentCornersPose(
            topLeft: simdToPoint3D(worldCorners[0]),
            topRight: simdToPoint3D(worldCorners[1]),
            bottomLeft: simdToPoint3D(worldCorners[2]),
            bottomRight: simdToPoint3D(worldCorners[3])
        )
    }

}
