---
title: "RBAC 权限模型：用户-团队-角色的设计与落地"
date: 2024-05-29T10:30:00+08:00
draft: false
tags: ["RBAC","权限","账号中台"]
categories: ["认证"]
description: "统一认证中心中用户-团队-角色 RBAC 模型的设计与落地"
---

## 问题背景

在统一认证中心之前，某科技公司内部各系统的权限模型五花八门：有的硬编码在代码里，有的用配置文件，有的甚至直接在数据库存用户和菜单的关联。人员入职换岗要在多个系统分别改权限，审计时根本说不清谁有什么权限。我们需要一套标准的 RBAC 模型，把用户、团队、角色、权限点的关系收敛到统一认证中心，并且能支撑前面提到的 AppRole 应用自治。

## 方案设计

经典 RBAC 是用户-角色-权限三层，但我们多了团队这个维度，变成用户-团队-角色-权限。核心实体：User（用户）、Team（团队）、Role（角色，分为全局角色和 AppRole）、Permission（权限点）。用户和团队是多对多，用户在团队里通过 TeamMember 关联到一个或多个角色。权限点用"资源:操作"的格式，比如 dataset:read、order:refund。角色绑定权限点，用户通过角色间接获得权限。我们还支持角色继承：team-admin 继承 team-viewer 的所有权限，减少重复配置。

## 关键代码

```go
type Role struct {
    ID        int64  `gorm:"primaryKey"`
    AppID     string `gorm:"index"` // 空表示全局角色
    Code      string `gorm:"size:64;uniqueIndex:idx_app_code"`
    Name      string `gorm:"size:128"`
    ParentID  int64  // 角色继承
    IsBuiltin bool
}

type RolePermission struct {
    RoleID     int64  `gorm:"uniqueIndex:idx_role_perm"`
    Permission string `gorm:"uniqueIndex:idx_role_perm;size:64"`
}

func (s *Service) ListUserPermissions(ctx context.Context,
    userID, teamID int64, appID string) ([]string, error) {

    roles, err := s.memberDAO.ListRoles(ctx, teamID, userID, appID)
    if err != nil {
        return nil, err
    }
    // 展开继承链上的所有角色
    allRoles, err := s.roleDAO.ExpandWithParents(ctx, roles)
    if err != nil {
        return nil, err
    }
    return s.permDAO.ListByRoleIDs(ctx, allRoles)
}
```

鉴权分两级：网关层做粗粒度（这个 Token 能不能访问这个路由），用 JWT 里带的角色信息判断；业务服务层做细粒度（能不能操作这条数据），通过 gRPC 调统一认证中心的 CheckPermission 或读本地权限缓存。我们用 Redis 缓存用户权限列表，key 是 `perm:{teamID}:{userID}:{appID}`，成员关系或角色变更时主动失效。

## 踩坑与权衡

权限缓存的一致性是个老大难问题。最初在成员变更时只删当前用户的缓存，但角色权限变更时要删这个角色下所有用户的缓存，用户多时会有缓存击穿。后来改成版本号方案：每个团队的权限版本号存在 Redis，缓存 key 带版本号，变更时递增版本号，旧缓存自然过期，虽然会有短暂的新旧权限并存窗口，但在可接受范围内。另一个权衡是权限点粒度，太细了配置维护成本高，太粗了达不到管控效果，我们的经验是按业务操作定义，一个接口对应一个权限点，特殊操作再细分。

## 小结

用户-团队-角色-权限的 RBAC 模型在统一认证中心落地后，人员入转调离只需要在一处改权限，审计也能统一导出。配合 AppRole 应用自治和权限缓存，既保证了安全管控的统一性，又没有牺牲各业务线的灵活性。这套模型后来也复用到了 alchemy-furnace 开源项目里，证明了它在不同规模场景下都是适用的。
