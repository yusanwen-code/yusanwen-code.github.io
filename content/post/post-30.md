---
title: "KubeSphere 容器化部署最佳实践：发布效率提升 80%"
slug: "post-30"
date: 2024-12-02T10:30:00+08:00
draft: false
image: /images/post-30-cover.jpg
tags: ["KubeSphere","Docker","Kubernetes"]
categories: ["DevOps"]
description: "从构建到灰度发布的容器化落地经验"
---

## 靠手速回滚的日子

我之前负责一个 AI 数据平台的后端架构，平台里跑着支付、认证、数据治理、数据集管理、知识库问答这一批服务。早期都部署在虚拟机上，Shell 脚本加 Docker Compose 管：每次发布要 SSH 到各台机器拉镜像、重启容器，流程繁琐还容易出错，回滚更是靠手速。发布密集的那阵子，开发和运维都苦不堪言。

我们决定整体迁到 KubeSphere，目标就两条：发布流程标准化、自动化；回滚压到分钟级。

## 一条流水线

流程本身不复杂：代码合并到主分支后，GitLab CI（或 Jenkins）执行 Docker Build，镜像推到私有仓库，KubeSphere 里的 `Deployment` 拉新镜像做滚动更新。

配置上有几处是刻意选的：

- Dockerfile 用多阶段构建，编译阶段跑在 Go 基础镜像里，运行阶段换 Alpine，把镜像压小；
- 滚动更新用 `RollingUpdate`，`maxSurge=1`、`maxUnavailable=0`，发布期间服务不中断；
- Liveness/Readiness 探针职责分开：健康检查失败自动重启，未就绪的 Pod 不接流量；
- 配置和密钥走 ConfigMap + Secret，环境变量或 Volume 挂载，不进镜像；
- 灰度用 KubeSphere 基于 Istio 的金丝雀发布，按比例放流量。

![从代码合并到滚动更新的发布链路](/images/post-30-k8s-pipeline.svg)

## 镜像怎么瘦下来的

多阶段构建的 Dockerfile，以 Go 服务为例：

```dockerfile
# 构建阶段
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o app ./cmd/server

# 运行阶段
FROM alpine:3.19
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /app
COPY --from=builder /app/app .
EXPOSE 8080
ENTRYPOINT ["./app"]
```

## 发布不中断的三个开关

Deployment 的滚动更新和探针配置：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat-api
  namespace: ai-platform
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: chat-api
  template:
    spec:
      containers:
        - name: chat-api
          image: registry.example.com/ai/chat-api:v1.2.0
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2"
              memory: "2Gi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          env:
            - name: DB_DSN
              valueFrom:
                secretKeyRef:
                  name: chat-api-secret
                  key: dsn
```

## CI：构建、推送、换镜像

CI 中构建并推送镜像的片段：

```yaml
build-and-push:
  stage: deploy
  script:
    - docker build -t $REGISTRY/chat-api:$CI_COMMIT_SHORT_SHA .
    - docker login $REGISTRY -u $CI_USER -p $CI_PASS
    - docker push $REGISTRY/chat-api:$CI_COMMIT_SHORT_SHA
    - kubectl set image deployment/chat-api chat-api=$REGISTRY/chat-api:$CI_COMMIT_SHORT_SHA -n ai-platform
```

## 五个坑

镜像体积是第一个意外。最初用 Ubuntu 基础镜像，单个 600MB 起步；换成 Alpine 加多阶段构建后压到 20MB 左右，拉取速度快了一个量级。有个前提要注意：Alpine 用 musl libc，CGO 依赖的库编译时要静态链接。

第二个坑在探针上。liveness 的 `initialDelaySeconds` 设短了，Go 服务还没初始化完就被判死重启，直接 CrashLoopBackOff。后来按各服务实际启动时间调到 10 到 15 秒。readiness 负责流量摘除，和 liveness 的职责要分开，别混着用。

资源限制不设不行。没有 limits 的服务会和邻居争抢资源，整个节点都可能被拖得不稳。我们统一了 requests/limits 的规范，具体数值拿开发环境压测结果定。

灰度有隐藏成本。KubeSphere 的金丝雀发布基于 Istio，第一次接入时 Sidecar 注入让请求延迟多了约 20ms。对知识库问答服务这种流式响应影响不大，但统一支付平台那种对延迟敏感的场景就要掂量一下。

回滚反而是最省心的。滚动更新天然保留上一个 ReplicaSet，出问题 `kubectl rollout undo` 一条命令，KubeSphere 控制台上也是一键操作，基本 5 分钟内能退回稳定版本。

## 后来

迁移完成后，发布从人工 SSH 变成 CI 自动跑，发布效率提升约 80%，故障回滚控制在 5 分钟内。还有个附带的好处：新同事入职不用再背部署文档，打开 KubeSphere 界面，服务拓扑自己就看明白了。

> 封面图：[roger4336 / Flickr](https://www.flickr.com/photos/24736216@N07/5696972687) · CC BY-SA 2.0
