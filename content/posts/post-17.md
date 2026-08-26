---
title: "AppRole 与应用团队隔离：多业务线权限自治的实现"
date: 2024-05-13T10:30:00+08:00
draft: false
tags: ["RBAC","权限模型","多租户"]
categories: ["认证"]
description: "统一认证中心中 AppRole 与团队隔离实现多业务线权限自治"
---

## 问题背景

统一认证中心接入的应用越来越多，权限模型也变复杂了。统一支付平台有运营、财务、商户管理员等角色；数据治理服务有数据管理员、分析师；数据集管理服务又有自己的文档管理员。如果所有角色都在统一认证中心全局定义，角色表会爆炸，而且各业务线想改自己的角色还得找认证中心团队，完全没法自治。我们需要一层"应用角色（AppRole）"的概念，让每个应用管理自己的角色，同时统一认证中心还能做跨应用的团队隔离。

## 方案设计

我们把权限分成两层：统一认证中心全局层管团队（Team）和成员关系，应用层管 AppRole。一个用户在一个团队里可以对不同应用有不同 AppRole。比如张三在"数据中台团队"里对数据治理服务是 admin，对知识库问答服务只是 viewer。团队是隔离边界，数据、配置、成员都按 team_id 隔离，跨团队访问必须显式授权。AppRole 由应用自己定义角色编码（如 admin/editor/viewer）和对应的权限点，统一认证中心只存绑定关系，不关心具体权限点的含义。

## 关键代码

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

JWT 里我们带了当前 team_id 和各应用的 role 映射，业务系统在本地就能做粗粒度鉴权，细粒度权限点再查统一认证中心或读缓存。团队隔离在 DAO 层强制，所有查询都带 team_id 条件，我们用 Gorm 的 Scopes 封装了一个 WithTeam 范围，避免漏写。

## 踩坑与权衡

最大的坑是"切换团队"的场景。一个用户可能属于多个团队，Token 里只能放当前 team_id，切换团队要重新签发 Token。我们最初想把所有团队都塞 Token 里，但团队多了 Token 会很大，超过 HTTP 头大小限制。后来改成 Token 里只放当前团队，提供 switch-team 接口重新签发，前端切换时调用。另一个坑是 AppRole 由应用自定义后，统一认证中心管理后台没法做统一的权限点展示，我们让应用注册一个权限元数据接口，统一认证中心拉取后展示，虽然多了一次对接但换来了自治。

## 小结

AppRole 加 Team 的两层模型让全局管控和应用自治达到了平衡：统一认证中心管身份和团队边界，应用自己管角色和权限点。这套设计在我们接入统一支付平台、数据治理服务、知识库问答服务多个业务线后被证明是可扩展的，新应用接入时定义自己的角色即可，不需要改认证中心的表结构。
