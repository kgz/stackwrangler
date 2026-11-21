"""Give LocalEmu's state dir to the ``localemu`` user before it drops root (#754).

``up --dev`` bind-mounts ``.awsbox/dev/localemu`` at ``/var/lib/localemu``. The host
creates that dir as whoever runs the CLI; the entrypoint later ``setpriv``s to
``localemu`` (uid 1000), which then can't create ``lib``/``cache``/… unless the host
user happened to be uid 1000. boot.d runs as root, so fix ownership here.
"""

import logging
import os
import pwd

LOG = logging.getLogger("localemu.awsbox.dev_state_owner")
STATE = "/var/lib/localemu"

try:
    user = pwd.getpwnam("localemu")
except KeyError:
    user = None

if user is not None and os.geteuid() == 0 and os.path.isdir(STATE):
    if os.stat(STATE).st_uid != user.pw_uid:
        for root, dirs, files in os.walk(STATE):
            for name in [root, *(os.path.join(root, n) for n in dirs + files)]:
                try:
                    os.lchown(name, user.pw_uid, user.pw_gid)
                except OSError:
                    LOG.debug("chown %s failed", name, exc_info=True)
        LOG.info("%s handed to localemu (%d) for dev-mode state", STATE, user.pw_uid)
