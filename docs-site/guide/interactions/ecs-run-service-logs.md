# ECS Run task / Create service / task logs

Console cluster detail exposes **Run task** and **Create service** thin forms (`/ecs/clusters/:name/run-task`, `/ecs/clusters/:name/create-service`). Both call LocalEmu `RunTask` / `CreateService` with launch type Fargate. Subnet and security group fields are optional for bridge/host task definitions and required for awsvpc / Fargate.

Task detail **Stop** calls `StopTask`. The **Logs** panel reads the task definition `logConfiguration`: when `logDriver` is `awslogs`, it shows the log group / stream and links to CloudWatch Logs (`FilterLogEvents` when streams exist). Without awslogs, the panel stays an honest stub.

Open Design mocks: `design/stackwrangler-console/screens/ecs-run-task.html`, `ecs-create-service.html`, updated `ecs-cluster-detail.html` / `ecs-task-detail.html` (#545).
