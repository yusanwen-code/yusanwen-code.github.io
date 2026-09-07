---
title: "RBAC 权限模型：用户-团队-角色的设计与落地"
slug: "post-18"
date: 2024-05-29T10:30:00+08:00
draft: false
image: /images/post-18-cover.jpg
tags: ["RBAC","权限","账号中台"]
categories: ["认证"]
description: "统一认证中心中用户-团队-角色 RBAC 模型的设计与落地"
---

## 权限模型五花八门

统一认证中心之前，各系统的权限模型五花八门：有的把权限硬编码在代码里，有的用配置文件，还有的直接在数据库里存用户和菜单的关联。人员入职、换岗，得在每个系统分别改一遍权限；真到审计的时候，谁到底有什么权限，根本说不清。

所以要做的就是把用户、团队、角色、权限点收敛到统一认证中心一处管理，同时还得支撑前面说过的 AppRole 应用自治。

## 比经典 RBAC 多一层团队

经典 RBAC 是用户-角色-权限三层，我们在中间加了团队，变成用户-团队-角色-权限。核心实体四个：User、Team、Role、Permission。用户和团队多对多，进了团队之后，通过 TeamMember 关联一个或多个角色。角色分全局角色和 AppRole 两种；权限点用「资源:操作」的格式，比如 dataset:read、order:refund，角色绑定权限点，用户经由角色间接拿到权限。

还支持角色继承：team-admin 继承 team-viewer 的全部权限，管理员比普通成员多出一堆权限这种常见配置，就不用重复维护了。

![用户-团队-角色-权限：模型与鉴权链路](/images/post-18-rbac-model.svg)

## 查权限就是展开继承链

角色定义和角色-权限绑定是两张表：

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

ListUserPermissions 做的事不复杂：先查出用户在这个团队、这个应用上的角色，把继承链上的父角色全部展开，最后汇总权限点。

鉴权分两级。网关层做粗粒度：这个 Token 能不能访问这个路由，用 JWT 里带的角色信息判断就够。业务服务层做细粒度：能不能操作这条数据，通过 gRPC 调统一认证中心的 CheckPermission，或者读本地权限缓存。缓存用 Redis，key 是 perm:{teamID}:{userID}:{appID}，成员关系或角色变更时主动失效。

## 缓存这坑最深

权限缓存的一致性，是最初低估了的部分。成员变更时只删当前用户的缓存，这没问题；但角色权限变更时，得把这个角色下所有用户的缓存都删掉，用户一多就是缓存击穿。

后来改成版本号方案：每个团队的权限版本号存在 Redis，缓存 key 带上版本号，变更时递增版本，旧缓存自然过期。代价是新旧权限会有短暂的并存窗口，评估下来可以接受。

粒度是另一件要拿捏的事。权限点切得太细，配置维护成本高；太粗又起不到管控效果。我们的经验是按业务操作定义，一个接口一个权限点，特殊操作再细分。

## 后来

这套模型落地之后，人员的入转调离只需要在一处改权限，审计也能统一导出。配上 AppRole 的应用自治和带版本号的权限缓存，安全管控是统一的，业务线的灵活性没有牺牲。这套用户-团队-角色-权限的模型后来还复用到了 alchemy-furnace 开源项目里，换了个场景，依然适用。
