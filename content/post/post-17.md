---
title: "AppRole 与应用团队隔离：多业务线权限自治的实现"
slug: "post-17"
date: 2024-05-13T10:30:00+08:00
draft: false
image: /images/post-17-cover.jpg
tags: ["RBAC","权限模型","多租户"]
categories: ["认证"]
description: "统一认证中心中 AppRole 与团队隔离实现多业务线权限自治"
---

## 角色表快撑不住了

统一认证中心接入的应用越来越多，权限模型先扛不住了。支付平台有运营、财务、商户管理员这些角色；数据治理服务有数据管理员、分析师；数据集管理服务又有自己的文档管理员。要是所有角色都放到认证中心全局定义，角色表迟早撑爆，而且业务线想调整自己的角色，还得来找认证中心团队，自治无从谈起。

我们需要一层「应用角色（AppRole）」：每个应用自己定义、自己管理角色，认证中心只负责团队隔离。

## 认证中心管边界，应用管角色

做法是把权限拆成两层。认证中心全局层只管团队（Team）和成员关系，应用层管 AppRole。一个用户在同一个团队里，对不同应用可以有不同角色：张三在数据中台团队里，对数据治理服务是 admin，对知识库问答就只是 viewer。

团队是隔离边界，数据、配置、成员都按 team_id 隔离，跨团队访问必须显式授权。AppRole 的角色编码（admin/editor/viewer 这类）和对应权限点由应用自己定义，认证中心只存绑定关系，不关心权限点具体是什么意思。

![AppRole + Team 两层权限模型](/images/post-17-approle-team.svg)

## 查权限就是查一次绑定

绑定关系就一张表，team_id、user_id、app_id 联合唯一，AppRole 字段存的是应用自己定义的角色编码：

```go
type TeamMember struct {
    ID       int64  `gorm:"primaryKey"`
    TeamID   int64  `gorm:"uniqueIndex:idx_team_user_app"`
    UserID   int64  `gorm:"uniqueIndex:idx_team_user_app"`
    AppID    string `gorm:"uniqueIndex:idx_team_user_app"`
    AppRole  string `gorm:"size:32"` // 应用自定义角色编码
}

func (s *Service) CheckPermission(ctx context.Context,
    userID, teamID int64, appID, perm string) bool {

    member, err := s.memberDAO.Get(ctx, teamID, userID, appID)
    if err != nil {
        return false
    }
    // 应用通过接口返回角色 -> 权限点映射
    perms, err := s.appProvider.GetPermissions(ctx, appID, member.AppRole)
    if err != nil {
        return false
    }
    for _, p := range perms {
        if p == perm || p == "*" {
            return true
        }
    }
    return false
}
```

CheckPermission 的逻辑很直白：查出用户在这个团队、这个应用上的角色，再向应用要这个角色对应的权限点列表，匹配上就放行。角色到权限点的映射由应用自己实现，认证中心不做解释。

JWT 里带了当前 team_id 和各应用的 role 映射，业务系统在本地就能做粗粒度鉴权，细粒度权限点再查认证中心或读缓存。团队隔离则下沉到 DAO 层强制：所有查询都带 team_id 条件，我们用 Gorm 的 Scopes 封了个 WithTeam，免得哪次手写漏了。

## 两个坑

第一个是切换团队。用户可能同时属于多个团队，但 Token 里只能放一个当前 team_id。最初想把所有团队都塞进 Token，团队一多就超过 HTTP 头大小限制了。后来改成 Token 只放当前团队，加了个 switch-team 接口重新签发，前端切团队时调一下。

第二个是自治带出来的小代价：AppRole 让应用自己定义之后，认证中心管理后台没法统一展示权限点了。解决办法是让应用注册一个权限元数据接口，认证中心拉取后展示。多了一次对接，换来自治，这笔账算得过来。

## 后来

AppRole 加 Team 的两层模型，说到底是在全局管控和应用自治之间找平衡：认证中心管身份和团队边界，应用管自己的角色和权限点。后来支付平台、数据治理、知识库问答几条业务线先后接入，新应用进来定义好自己的角色就能用，认证中心的表结构不用动。

> 封面图：[bfi Office Furniture / Flickr](https://www.flickr.com/photos/94689970@N00/5187997234) · CC BY-SA 2.0
