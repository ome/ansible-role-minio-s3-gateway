#!/bin/bash
# https://github.com/minio/minio/tree/master/docs/multi-user
set -eu

BUCKETNAME="{{ minio_s3_gateway_bucket }}"

{% raw %}

if [ $# -lt 2 -o $# -gt 3 ]; then
    cat << EOF
USAGE: $(basename $0) connection-alias [add|remove] username
       $(basename $0) [add|remove] username

       connection-alias:
         If omitted uses "minio-s3-gateway" from /root/.mc/ (requires root
         access), otherwise it is taken from ~/.mc

       add:
         - create a user "username" with a random secret token
         - create a policy "policy-username" that gives "username"
           read/write/list/delete permissions on "$BUCKETNAME/username/*"
         - create a "$BUCKETNAME/username/README.txt" placeholder so that
           listing "$BUCKETNAME/username/" works
         - display the username and secret token
         - if the "username" already exists this replaces the secret token
           with a new one

       remove:
         - delete the policy "policy-username"
         - delete the user "username"
         - This will not delete or modify any data, so a user can be disabled
           by deleting them, and enabled by re-adding them

EOF
    exit 1
fi

if [ $# -eq 3 ]; then
    CONFIG_DIR=
    ADMIN_CONNECTION="$1"
    COMMAND="$2"
    USERNAME="$3"
else
    CONFIG_DIR="--config-dir /root/.mc"
    ADMIN_CONNECTION=minio-s3-gateway
    COMMAND="$1"
    USERNAME="$2"
fi
POLICY_NAME="policy-$USERNAME"

POLICY_TEMPLATE=/etc/minio-s3-gateway/policy-readwrite-subdir.json.template

if [[ ! $USERNAME =~ ^[a-z][a-z0-9-]{3,15}$ ]]; then
    echo "ERROR: Username must match regex [a-z][a-z0-9-]{3,15}: $USERNAME"
    exit 1
fi

# Not necessary for S3, but this avoids having to escape characters when
# modifying POLICY_TEMPLATE with sed
if [[ ! $BUCKETNAME =~ ^[a-z][a-z0-9-]{3,15}$ ]]; then
    echo "ERROR: BUCKETNAME must match regex [a-z][a-z0-9-]{3,15}: $BUCKETNAME"
    exit 1
fi

if [ "$COMMAND" = "add" ]; then
    SECRET=$(cat /dev/urandom | env LC_TYPE=C tr -dc 'a-zA-Z0-9' | head -c 30)
    if [ ${#SECRET} -ne 30 ]; then
        echo "Unexpected error whilst creating secret token"
        exit 2
    fi
    POLICY_FILE=$(mktemp)

    sed -e "s/{BUCKETNAME}/$BUCKETNAME/g" -e "s/{USERNAME}/$USERNAME/g" "$POLICY_TEMPLATE" > "$POLICY_FILE"
    mc $CONFIG_DIR admin policy add "$ADMIN_CONNECTION" "$POLICY_NAME" "$POLICY_FILE"

    mc $CONFIG_DIR admin user add "$ADMIN_CONNECTION" "$USERNAME" "$SECRET"
    mc $CONFIG_DIR admin policy set "$ADMIN_CONNECTION" "$POLICY_NAME" user="$USERNAME"

    mc $CONFIG_DIR cp /etc/minio-s3-gateway/README.txt "${ADMIN_CONNECTION}/${BUCKETNAME}/${USERNAME}/README.txt"

    echo "Access token: $USERNAME"
    echo "Secret token: $SECRET"
elif [ "$COMMAND" = "remove" ]; then
    mc $CONFIG_DIR admin policy remove "$ADMIN_CONNECTION" "$POLICY_NAME"
    mc $CONFIG_DIR admin user remove "$ADMIN_CONNECTION" "$USERNAME"
else
    echo "ERROR: invalid command"
    exit 1
fi

{% endraw %}
