import SwiftUI
import Spatial
import RealityKit
import VisionProKit

@MainActor
@Observable
class ViewfinderPoseModel {
    // 传入世界坐标系下的Point3D，顺序任意，我会重新判断谁是左手谁是右手
    func getViewfinderPose(hand1ControlPointWorld:Point3D,hand2ControlPointWorld:Point3D,head:Transform) throws -> ViewfinderOrnamentPose {
        // 重新计算左右手，即使用户把左右手交叉来，也确保取景框正面朝向用户
        // 在head局部坐标系内从左到右排
        let sortedArrayLeftToRight = [hand1ControlPointWorld,hand2ControlPointWorld].sorted {
            PointAndVectorAndTransformConverter.worldToLocal($0, head: head).x <
                PointAndVectorAndTransformConverter.worldToLocal($1, head: head).x
        }
        guard let leftHandWorld = sortedArrayLeftToRight.first, let rightHandWorld = sortedArrayLeftToRight.last else {
            throw GetViewfinderError()
        }
        let (leftHeadLocal, rightHeadLocal) = PointAndVectorAndTransformConverter.worldToLocal(leftHandWorld,rightHandWorld, head: head)
        return try getViewfinder(point1World: leftHandWorld, point1HeadLocal: leftHeadLocal, point2World: rightHandWorld, point2HeadLocal: rightHeadLocal, head: head)
    }
    
    // 我们总是认为point1是左手、point2是右手。
    // 在头部坐标系内，构造一个垂直于XZ平面的面，这个面应该刚好包含了point1和point2，同时这个面的X轴不应该和头部坐标系的XZ平面平行，而是应该和世界坐标系的XZ平面平行。
    private
    func getViewfinder(point1World:Point3D,point1HeadLocal:Point3D,point2World:Point3D,point2HeadLocal:Point3D,head:Transform) throws -> ViewfinderOrnamentPose {
        // 首先求目标方框的中心
        //  很简单，两个控制点的中心
        let centerWorld:Point3D = .init(vector: (point1World.vector + point2World.vector) / 2)
        // 求ViewfinderPlane的法向量
        let normalWorld = getViewfinderPlaneNormal(point1HeadLocal: point1HeadLocal, point2HeadLocal: point2HeadLocal, head: head)
        
        // 计算三条坐标轴
        // 记得过归一化
        // 做cross的顺序很重要，这里的顺序是经过测试的，确保可以正确构成坐标轴
        let zAxisWorld = normalWorld.normalized
        // X轴总是与世界Y轴垂直，确保取景框是水平的，“超级地平线防抖”，这样用户歪头照片不会歪
        let worldXZPlaneNormal:Vector3D = .init(x: 0, y: 1, z: 0)
        let xAxisWorld = zAxisWorld.cross(worldXZPlaneNormal).normalized
        // x轴和z轴都锁定了，计算出y轴
        let yAxisWorld = xAxisWorld.cross(zAxisWorld).normalized
        // 三条轴都有了，计算出Transform
        let viewfinderPlaneTransformWorld:Transform = PointAndVectorAndTransformConverter.makeMatrixSimplifiedL1(xAxis: xAxisWorld, yAxis: yAxisWorld, zAxis: zAxisWorld, center: centerWorld)
        
        // 计算宽高
        // 我们需要得到两个点的ViewfinderLocal坐标
        let point1ViewfinderLocal = PointAndVectorAndTransformConverter.worldToLocal(point1World, head: viewfinderPlaneTransformWorld)
        let point2ViewfinderLocal:Point3D = PointAndVectorAndTransformConverter.worldToLocal(point2World, head: viewfinderPlaneTransformWorld)
        
        // height就是两个高度一减
        // 高的减低的
        let height = max(point1ViewfinderLocal.y,point2ViewfinderLocal.y) - min(point1ViewfinderLocal.y,point2ViewfinderLocal.y)
        // width就是viewfinder在自己的X轴上的长度
        let width = length(Point3D(x: point1ViewfinderLocal.x, y: 0, z: point1ViewfinderLocal.z).vector - Point3D(x: point2ViewfinderLocal.x, y: 0, z: point2ViewfinderLocal.z).vector)
        
        return ViewfinderOrnamentPose(
            transform: viewfinderPlaneTransformWorld,
            size: .init(
                width: width,
                height: height
            )
        )
    }
    
    // 因为要与HeadLocal的XZ平面垂直，先求XZ平面的法向量
    // 虽然只要满足”平面法向量与XZ平面的法向量垂直”的任何法向量都满足垂直条件，但我们需要一个自然的选择。我选择的方法是：平面应该"对齐"于两点连线在XZ平面的投影方向。
    private
    func getViewfinderPlaneNormal(point1HeadLocal:Point3D,point2HeadLocal:Point3D,head:Transform) -> Vector3D {
        // 计算两点间的向量分量
        let dx = point2HeadLocal.x - point1HeadLocal.x
        let dz = point2HeadLocal.z - point1HeadLocal.z
        
        // 使用叉积（更几何直观）
        // XZ平面的法向量
        let yAxisHeadLocal = Vector3D(x: 0, y: 1, z: 0).normalized
        // 两点连线在XZ平面的投影
        let projVectorHeadLocal = Vector3D(x: dx, y: 0, z: dz).normalized
        // 叉积：垂直于两个向量
        let normalHeadLocal:Vector3D = yAxisHeadLocal.cross(projVectorHeadLocal).normalized
        let normalWorld:Vector3D = PointAndVectorAndTransformConverter.localToWorld(local: normalHeadLocal,head: head)
        return normalWorld
    }
    
    // 取景框的姿态
    struct ViewfinderOrnamentPose:Equatable {
        var transform:Transform
        struct Size2D:Equatable {
            var width:Double
            var height:Double
        }
        var size:Size2D // 宽高，米
    }
    
    struct GetViewfinderError:LocalizedError {
        var errorDescription: String? {
            "逻辑错误"
        }
    }
    
}
