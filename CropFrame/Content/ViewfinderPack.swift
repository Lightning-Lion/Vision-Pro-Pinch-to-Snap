import os
import Combine
import SwiftUI
import RealityKit
import VisionProKit

// 作为Pack，是包在最外面一层的，面向用户的接口，用户可以轻松在任意ImmersiveSpace里使用我
@MainActor
@Observable
class ViewfinderPack {
    private
    var ornamentAndCameraAndPose = ViewfinderOrnamentAndCameraAndPhotos()
    // baseEntity是外面给我们的一个接口，因为直接传递RealityViewContent很麻烦，故使用baseEntity替代
    func run(baseEntity:Entity,dismissImmersiveSpace:DismissImmersiveSpaceAction) async {
        await ornamentAndCameraAndPose.run(
            baseEntity: baseEntity,
            dismissImmersiveSpace: dismissImmersiveSpace
        )
    }
    func modifier(baseEntity:Entity) -> ViewfinderPackModifier {
        ViewfinderPackModifier(context: ornamentAndCameraAndPose, baseEntity: baseEntity)
    }
}
// 对外的接口，不写实际逻辑
struct ViewfinderPackModifier: ViewModifier {
    @State
    fileprivate var context:ViewfinderOrnamentAndCameraAndPhotos
    var baseEntity:Entity
    func body(content: Content) -> some View {
        content
            .modifier(ViewfinderOrnamentAndCameraAndPhotosModifier(context: context, baseEntity: baseEntity))
    }
}


// 我们也别封这么多层，Java思维来了，到时候还是堆成屎山
// 封的目的只是让我们改每个模块的时候知道看哪个文件、往哪里改，不用在一个超大单体文件之中迷失
// 而不是所要做什么可插拔、可替换
@MainActor
@Observable
fileprivate class ViewfinderOrnamentAndCameraAndPhotos {
    // 三个模块，一个负责取景框的UI和姿态，另一个负责拍照，另一个负责照片的呈现
    var viewfinderSystem:ViewfinderOrnamentSystem = ViewfinderOrnamentSystem()
    var cameraModel = CameraWithHead()
    var photosModel = PhotosModel()
    private
    var deiniter = ImmersiveSpaceDestoryDetector()
    private
    var projectorLeft:ThreeDTo2DProjector? = nil
    private
    var projectorRight:ThreeDTo2DProjector? = nil
    func run(baseEntity:Entity,dismissImmersiveSpace:DismissImmersiveSpaceAction) async {
        // 注册ImmersiveSpace销毁事件
        deiniter.listenWillClose(baseEntity: baseEntity)
        // 启动UI和姿态
        await viewfinderSystem.mount(baseEntity: baseEntity, dismissImmersiveSpace: dismissImmersiveSpace,onShutterGesture: { pose,cornersPose in
            self.takaPhoto(pose: pose, cornersPose: cornersPose, baseEntity: baseEntity)
        })
        do {
            // 获取一下内外参
            let intrinsicAndExtrinsics:GetIntrinsicsAndExtrinsics.IntrinsicsAndExtrinsics = try await GetIntrinsicsAndExtrinsics().getIntrinsicsAndExtrinsics()
            self.projectorLeft = ThreeDTo2DProjector(camera: .left, intrinsicsAndExtrinsics: intrinsicAndExtrinsics)
            self.projectorRight = ThreeDTo2DProjector(camera: .right, intrinsicsAndExtrinsics: intrinsicAndExtrinsics)
            // 启动相机
            do {
                try await cameraModel.runCameraFrameProvider()
            } catch {
                // 捕捉启动相机的错误
                await dismissImmersiveSpace()
                onStartCameraError.send(error)
            }
        } catch {
            // 捕捉获取内外参的错误
            await dismissImmersiveSpace()
            onGetIntrinsicsAndExtrinsicsError.send(error)
        }
    }
    // pose是PhotosModelV1需要用
    // cornersPose是ThreeDTo2DProjector需要用
    func takaPhoto(
        pose:ViewfinderPoseModel.ViewfinderOrnamentPose,
        cornersPose:ViewfinderOrnamentPoseToCornersPose.ViewfinderOrnamentCornersPose,
        baseEntity:Entity
    ) {
        // 即刻创建照片实体、显示白色加载、加载完成后褪色为实际画面
        Task { @MainActor in
            var photoIDForError:UUID? = nil
            do {
                // 显示白色加载
                let photoID = try photosModel.takePhoto(pose: pose, baseEntity: baseEntity)
                photoIDForError = photoID
                // 拍照
                let photo = try await cameraModel.takePhoto()
                os_log("拍照成功")
                // 做裁切
                let (imageLeft,imageRight) = try await doCrop(photo: photo, cornersPose: cornersPose)
                // 上屏
                try await photosModel.doneLoading(photoID: photoID, imageLeftEye: imageLeft, imageRightEye: imageRight)
            } catch {
                os_log("\(error.localizedDescription)")
                // 尝试呈现错误
                do {
                    if let photoIDForError {
                        try photosModel.doneLoadingWithError(photoID: photoIDForError, error: error)
                    } else {
                        throw NoPhotoIDError()
                    }
                } catch {
                    os_log("\(error.localizedDescription)")
                }
            }
                
        }
    }
    // 取景框在3D中是一个矩阵
    // 但是投影在摄像头里就是一个四边形
    // 我们从相机照片里截取这个四边形，投影为矩形
    // 然后显示在3D中的取景框矩形里（不管上一步的裁切区域能给出多少分辨率，总是拉伸填满整个取景框）
    // 这样在摄像头看来它还是那个四边形
    private
    func doCrop(photo: CameraWithHead.Photo, cornersPose:ViewfinderOrnamentPoseToCornersPose.ViewfinderOrnamentCornersPose) async throws -> (imageLeft:CGImage,imageRight:CGImage) {
        do {
            guard let projectorLeft, let projectorRight else {
                throw TakaPhotoError.intrinsicAndExtrinsicsNotReady
            }
            let head:Transform = photo.head
            // 如果手在身后，无法获得2D点（即使是超出画布的），就会throw WorldToCameraError.pointNotInFront
            let cornersLeft:QuadrilateralCropper.Viewfinder2DCornersPose = try await projectorLeft.to2DCornersPoint(cornersPose: cornersPose, head: head)
            let cornersRight:QuadrilateralCropper.Viewfinder2DCornersPose = try await projectorRight.to2DCornersPoint(cornersPose: cornersPose, head: head)
            // 宽松裁切，如果部分在相机画面外，会得到部分或者全部透明的照片
            let imageLeft:CGImage = try await QuadrilateralCropper().cropInViewfinderPart(image: photo.left, twoDCorners: cornersLeft, strictness: .loose)
            let imageRight:CGImage = try await QuadrilateralCropper().cropInViewfinderPart(image: photo.right, twoDCorners: cornersRight, strictness: .loose)
            return (imageLeft,imageRight)
        } catch {
            os_log("\(error.localizedDescription)")
            throw error
        }
    }
    enum TakaPhotoError:LocalizedError {
        case intrinsicAndExtrinsicsNotReady
        var errorDescription: String? {
            switch self {
            case .intrinsicAndExtrinsicsNotReady:
                "内外参没有准备好"
            }
        }
    }
    struct NoPhotoIDError:LocalizedError {
        var errorDescription: String? {
            "无法呈现错误，因为照片拍摄就失败了"
        }
    }
}


fileprivate
struct ViewfinderOrnamentAndCameraAndPhotosModifier: ViewModifier {
    @State
    var context:ViewfinderOrnamentAndCameraAndPhotos
    var baseEntity:Entity
    func body(content: Content) -> some View {
        content
            .modifier(ViewfinderSystemModifier(system: context.viewfinderSystem, baseEntity: baseEntity))
            .modifier(CameraWithHeadModifier(model: context.cameraModel, baseEntity: baseEntity))
            .modifier(EnableDebugVis(baseEntity: baseEntity))
            // 我包在最外层
            .modifier(TriggerRealityViewDisappear())
    }
}


fileprivate
struct TriggerRealityViewDisappear: ViewModifier {
    // 我需要销毁我的RealityView，不然ImmersiveSpace的RealityKit上绑定的onDisappear事件不会被正常调用
    @State
    private var alive = true
    func body(content: Content) -> some View {
        VStack {
            if alive {
                content
            }
        }
            .onReceive(onClosingImmersiveSpace) { _ in
                os_log("已销毁")
                alive = false
            }
    }
}
