import os
import SwiftUI
import RealityKit
import VisionProKit

// 我持有拍摄的照片，和拍摄流程解耦
// 未来还可以加入持久化、反序列化逻辑
@MainActor
@Observable
class PhotosModel {
    var photos:[PhotoModel] = []
    // 返回photoID
    func takePhoto(pose:ViewfinderPoseModel.ViewfinderOrnamentPose, baseEntity:Entity) throws -> UUID {
        let newPhoto = PhotoModel(pose: pose)
        // 保持引用
        self.photos.append(newPhoto)
        // 显示加载画面
        let photoID:UUID = newPhoto.id
        try displaySkeleton(photoID: photoID, baseEntity: baseEntity)
        return photoID
    }
    private func displaySkeleton(photoID:UUID, baseEntity:Entity) throws {
        let photo = try getPhoto(photoID: photoID)
        guard photo.entity == nil else {
            os_log("重复调用，已返回")
            return
        }
        let photoEntity = Entity()
        // 登记已在处理，以便guard photo.entity == nil else {工作
        photo.entity = photoEntity
        // 宽高在视图内设置
        photoEntity.components.set(ViewAttachmentComponent(rootView: PhotoView(photo: photo)))
        baseEntity.addChild(photoEntity)
        // 姿态在我这里设置
        photoEntity.setTransformMatrix(photo.pose.transform.matrix, relativeTo: baseEntity)
    }
    func doneLoadingWithError(photoID:UUID,error:Error) throws {
        let photo = try getPhoto(photoID: photoID)
        photo.state = .error(error)
    }
    func doneLoading(photoID:UUID,imageLeftEye:CGImage,imageRightEye:CGImage) async throws {
        let photo = try getPhoto(photoID: photoID)
        // 外界传入左右眼图像，我转成立体Texture上屏
        let material:ShaderGraphMaterial = try await StereoMaterialModel().createMaterial(leftEye: imageLeftEye, rightEye: imageRightEye)
        photo.state = .done(PhotoModel.LoadedImage(left: imageLeftEye, right: imageRightEye, stereo: material))
    }
    private
    func getPhoto(photoID:UUID) throws -> PhotoModel {
        guard let matchedPhoto:PhotoModel = photos.first(where: { $0.id == photoID }) else {
            throw GetPhotoError.logicError
        }
        return matchedPhoto
    }
    enum GetPhotoError:LocalizedError {
        case logicError
        var errorDescription: String? {
            switch self {
            case .logicError:
                "逻辑错误偶"
            }
        }
    }
    enum GetBaseEntityError:LocalizedError {
        case notRun
        var errorDescription: String? {
            switch self {
            case .notRun:
                "还未运行run()"
            }
        }
    }
    enum DoneLoadingError:LocalizedError {
        case logicError
        var errorDescription: String? {
            switch self {
            case .logicError:
                "逻辑错误偶"
            }
        }
    }
    // 还可以负责持久化、反序列化、iCloud同步等操作
}

// 一张照片的数据结构，因为照片是懒加载的，所以有加载状态
// 我只存储数据，就像一个结构体，逻辑都在PhotosModelV1里
@MainActor
@Observable
class PhotoModel {
    var id = UUID()
    var pose:ViewfinderPoseModel.ViewfinderOrnamentPose
    var state:PhotoState = .loading
    var entity:Entity? = nil
    init(pose: ViewfinderPoseModel.ViewfinderOrnamentPose) {
        self.pose = pose
    }
    enum PhotoState {
        case loading
        case error(Error)
        case done(LoadedImage)
    }
    // 可以在创建后自由切换
    struct LoadedImage {
        var left:CGImage
        var right:CGImage
        var stereo:ShaderGraphMaterial
    }
}
