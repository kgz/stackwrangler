"""Install CodeDeploy create_deployment hooks at boot (#98 / #207).

ecs_ec2_services.install() is otherwise deferred until the ECS provider loads,
so a Lambda-only CodeDeploy call would leave status at Created.
"""
from localemu.services.ecs.ec2_services import install

install()
