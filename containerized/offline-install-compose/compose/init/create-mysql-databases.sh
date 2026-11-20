#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
# First-volume initialization only. Keep SQL identifiers and string literals apart.
set -euo pipefail
for identifier in "$REGISTRY_DB_NAME" "$REGISTRY_DB_USERNAME" "$ORCH_DB_NAME" "$ORCH_DB_USERNAME"; do
    [[ "$identifier" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo 'Invalid SQL identifier' >&2; exit 1; }
done
# NO_BACKSLASH_ESCAPES + doubled quotes preserves backslashes/apostrophes/$.
rc_password="${REGISTRY_DB_PASSWORD//\'/\'\'}"
oc_password="${ORCH_DB_PASSWORD//\'/\'\'}"
MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=socket -u root <<EOSQL
SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES';
CREATE DATABASE \`$REGISTRY_DB_NAME\` CHARACTER SET utf8mb4;
CREATE USER '$REGISTRY_DB_USERNAME'@'%' IDENTIFIED BY '$rc_password';
GRANT ALL PRIVILEGES ON \`$REGISTRY_DB_NAME\`.* TO '$REGISTRY_DB_USERNAME'@'%';
CREATE DATABASE \`$ORCH_DB_NAME\` CHARACTER SET utf8mb4;
CREATE USER '$ORCH_DB_USERNAME'@'%' IDENTIFIED BY '$oc_password';
GRANT ALL PRIVILEGES ON \`$ORCH_DB_NAME\`.* TO '$ORCH_DB_USERNAME'@'%';
EOSQL
