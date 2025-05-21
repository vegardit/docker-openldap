# vegardit/openldap <a href="https://github.com/vegardit/docker-openldap/" title="GitHub Repo"><img height="30" src="https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/github.svg?sanitize=true"></a>

[![Build Status](https://github.com/vegardit/docker-openldap/workflows/Build/badge.svg "GitHub Actions")](https://github.com/vegardit/docker-openldap/actions?query=workflow%3ABuild)
[![License](https://img.shields.io/github/license/vegardit/docker-openldap.svg?label=license)](#license)
[![Docker Pulls](https://img.shields.io/docker/pulls/vegardit/openldap.svg)](https://hub.docker.com/r/vegardit/openldap)
[![Docker Stars](https://img.shields.io/docker/stars/vegardit/openldap.svg)](https://hub.docker.com/r/vegardit/openldap)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-v2.1%20adopted-ff69b4.svg)](CODE_OF_CONDUCT.md)

1. [What is it?](#what-is-it)
1. [Configuration](#config)
   1. [Initial configuration](#initial-config)
   1. [Initial LDAP tree](#initial_ldaptree)
   1. [Customizing the Password Policy](#ppolicy)
   1. [Transport Encryption (LDAPS/STARTTLS)](#transport_encryption)
   1. [Changing UID/GID of OpenLDAP service user](#uidgid)
   1. [Periodic LDAP Backup](#backup)
   1. [Synchronizing timezone/time with docker host](#timesync)
   1. [Performance tuning](#performance-tuning)
   1. [Troubleshooting](#troubleshooting)
1. [References](#references)
1. [License](#license)


## <a name="what-is-it"></a>What is it?

An opinionated, multi-arch Docker image - currently based on [Debian](https://www.debian.org/)'s [`debian:bookworm-slim`](https://hub.docker.com/_/debian/tags?name=bookworm-slim) -
built for easy deployment of an [OpenLDAP 2.5](https://www.openldap.org/doc/admin25/) server.

Automatically rebuilt **weekly** to include the latest OS security fixes.

## <a name="config"></a>Configuration

### <a name="initial-config"></a>Initial configuration

Various parts of the LDAP server can be configured via environment variables. All environment variables starting with `LDAP_INIT_`
are only evaluated on the **first** container launch. Changing their values later has no effect when restarting or updating the container.

To customize the **initial** configuration you can set the following environment variables:

```sh
LDAP_INIT_ORG_DN='DC=example,DC=com'
LDAP_INIT_ORG_NAME='Example Corporation'
LDAP_INIT_ORG_ATTR_O='' # optional, if not defined will be derived from LDAP_INIT_ORG_DN, e.g. DC=example,DC=com -> example.com
LDAP_INIT_ADMIN_GROUP_DN='cn=ldap-admins,ou=Groups,${LDAP_INIT_ORG_DN}'
LDAP_INIT_PASSWORD_RESET_GROUP_DN='cn=ldap-password-reset,ou=Groups,${LDAP_INIT_ORG_DN}' # users in this group can set password/sshPublicKey attribute of other users
LDAP_INIT_ROOT_USER_DN='uid=admin,${LDAP_INIT_ORG_DN}'
LDAP_INIT_ROOT_USER_PW='changeit'
LDAP_INIT_RFC2307BIS_SCHEMA=0 # 0=use NIS (RFC2307) schema, 1=use RFC2307bis schema
LDAP_INIT_ALLOW_CONFIG_ACCESS='true' # if set to true, the "cn=config" namespace can be read/edited by LDAP admins
```

Environment variables can for example be set in one of the following ways:

1. Using `docker run` with `-e`, e.g.

   ```sh
   docker run -itd \
     -e LDAP_INIT_ORG_DN='DC=example,DC=com' \
     -e LDAP_INIT_ROOT_USER_PW='newpassword' \
     -e LDAP_INIT_ORG_NAME='Example Corporation' \
     -e LDAP_INIT_PPOLICY_PW_MIN_LENGTH='12' \
     -v /my_data/ldap/var/:/var/lib/ldap/ \
     -v /my_data/ldap/etc/:/etc/ldap/slapd.d/ \
     -p 389:389 \
     vegardit/openldap
   ```

1. Using an [env-file](https://docs.docker.com/compose/env-file/) to store all changed variables and use the option `--env-file` with `docker run`, e.g.:

   ```sh
   docker run -itd --env-file environment vegardit/openldap
   ```

   In the env-file values must not be enclosed using quotes (`'` or `"`), please remove them. See this example file: [example/docker/example.env](example/docker/example.env).

1. Setting the environment variable `INIT_SH_FILE` pointing to a shell script that should be sourced during the container start.

   ```sh
   # /path/on/docker/host/my_init.sh
   LDAP_INIT_ORG_DN='DC=example,DC=com'
   LDAP_INIT_ROOT_USER_PW='newpassword'
   LDAP_INIT_ORG_NAME='Example Corporation'
   LDAP_INIT_PPOLICY_PW_MIN_LENGTH='12'
   ```

   ```sh
   docker run -itd \
     -e INIT_SH_FILE=/mnt/my_init.sh \
     -v /path/on/docker/host/my_init.sh:/mnt/my_init.sh:ro \
     vegardit/openldap
   ```

### <a name="initial_ldaptree"></a>Initial LDAP tree

The initial LDAP tree structure is imported from [/opt/ldifs/init_org_tree.ldif](image/ldifs/init_org_tree.ldif).
You can mount a custom file at that path if you need changes.

LDAP entries (users, groups) are imported from [/opt/ldifs/init_org_entries.ldif](image/ldifs/init_org_entries.ldif).
You can mount a custom file at that path if you need changes.

### <a name="ppolicy"></a>Customizing the Password Policy

On **initial** container launch, the [password policy](https://www.openldap.org/doc/admin24/overlays.html#Password%20Policies) is imported from [/opt/ldifs/init_org_ppolicy.ldif](image/ldifs/init_org_ppolicy.ldif).

The following parameters can be modified via environment variables **before** initial container launch:

```sh
LDAP_INIT_PPOLICY_DEFAULT_DN='cn=DefaultPasswordPolicy,ou=Policies,${LDAP_INIT_ORG_DN}'
LDAP_INIT_PPOLICY_PW_MIN_LENGTH=8
LDAP_INIT_PPOLICY_MAX_FAILURES=3
LDAP_INIT_PPOLICY_LOCKOUT_DURATION=300
```

If more customizations are required, simply mount a custom policy file at `/opt/ldifs/init_org_ppolicy.ldif` **before** initial container launch.

**Password Quality Checker:**

[pqChecker](https://www.meddeb.net/pqchecker/) is configured as the default password quality checker using the rule `0|01010101` with
the following meaning:

|Pos. |Value  |Effective Rule
|----:|:-----:|:----------
|0-1  | `0\|` |Don't broadcast passwords.
|2-4  | `01`  |Minimum 1 uppercase character.
|5-6  | `01`  |Minimum 1 lowercase character.
|7-8  | `01`  |Minimum 1 digit.
|9-10 | `01`  |Minimum 1 special character.
|11-..| empty | No characters are disallowed in passwords.

The pqChecker rule syntax is explained here in more detail: https://www.meddeb.net/pqchecker/?Idx=2

A custom rule can be provided via an environment variable, e.g.:

```sh
LDAP_PPOLICY_PQCHECKER_RULE='0|01020101@!+-#'
```

### <a name="transport_encryption"></a>Transport Encryption (LDAPS/STARTTLS)

LDAP traffic can be encrypted in **two** complementary ways:

1. **Terminate TLS inside the container** using *static* X.509 certificates:

    * Bind-mount your TLS key material to the container to enable STARTTLS on port 389
    * Optionally enable **LDAPS** as well (TLS-wrapped LDAP port 636)

    |Variable                |Default                       |Description
    |------------------------|------------------------------|-----------
    |`LDAP_TLS_ENABLED`      |`auto`                        |Controls whether TLS features are activated:<br>- `auto` - activate TLS only if both certificate and private key are present at `/etc/ldap/certs/server.{crt,key}` (or supplied via `LDAP_TLS_CERT_FILE`/`LDAP_TLS_KEY_FILE`)<br>- `true` - always enable TLS; fail startup if certificate or private key is missing<br>- `false` - disable all TLS features; ignore other TLS settings
    |`LDAP_LDAPS_ENABLED`    |`true`                        |*(Only applies if TLS is enabled)*<br>`true` - enable implicit TLS (LDAPS) listener on port 636 (`ldaps://`)
    |`LDAP_TLS_CERT_FILE`    |`/run/secrets/ldap/server.crt`|Path to the server certificate **inside** the container
    |`LDAP_TLS_KEY_FILE`     |`/run/secrets/ldap/server.key`|Path to the matching private key **inside** the container
    |`LDAP_TLS_CA_FILE`      |`/run/secrets/ldap/ca.crt`    |Path to the CA bundle for verifying *peer* certificates
    |`LDAP_TLS_VERIFY_CLIENT`|`try`                         |Client certificate policy (see [`TLSVerifyClient`](https://www.openldap.org/doc/admin25/guide.html#TLSVerifyClient%20%7B%20never%20%7C%20allow%20%7C%20try%20%7C%20demand%20%7B)):<br>- `never` - don't request a client certificate<br>- `allow` - request a client certificate; ignore if missing or invalid<br>- `try` - request a client certificate; reject if invalid (ignore if missing)<br>- `demand` - require a valid client certificate
    |`LDAP_TLS_SSF`          |`128`                         |Minimum **Security Strength Factor** (SSF) required for **all** TLS sessions. `0` = clear-text allowed; `>=0` enforces that STARTTLS/LDAPS negotiate at minimum that strength (AES-128, AES-256). More details here: [OpenLDAP Admin Guide](https://www.openldap.org/doc/admin25/guide.html#Security%20Strength%20Factors)

    *How to generate a self-signed cert for testing:*

    ```bash
    openssl req -x509 -nodes -newkey rsa:4096 \
      -keyout server.key -out server.crt \
      -days 365 -sha256 \
      -subj "/CN=ldap.example.com" \
      -addext "subjectAltName=DNS:ldap.example.com"
    ```

    **Docker Compose example with bind-mount at default location:**

    Mounting the key and certificate to the default location will automatically enable STARTTLS and LDAPS support.

    ```yaml
    services:
      openldap:
        image: vegardit/openldap:latest
        environment:
          # ... other options
        ports:
          - "389:389"  # for STARTTLS
          - "636:636"  # for LDAPS
        volumes:
          - ./certs/server.crt:/run/secrets/ldap/server.crt:ro
          - ./certs/server.key:/run/secrets/ldap/server.key:ro
          - ./certs/ca.crt:/run/secrets/ldap/ca.crt:ro  # optional, if using a private CA
    ```

    **Docker Compose example with bind-mount at custom location:**

    Pointing LDAP_TLS_KEY_FILE and LDAP_TLS_CRT_FILE to paths accessible from within the container will automatically enable STARTTLS and LDAPS support.

    ```yaml
    services:
      openldap:
        image: vegardit/openldap:latest
        environment:
          LDAP_TLS_KEY_FILE: /opt/tls/server.key
          LDAP_TLS_CERT_FILE: /opt/tls/server.crt
          # ... other options
        ports:
          - "389:389"  # for STARTTLS
          - "636:636"  # for LDAPS
        volumes:
          - ./certs/:/opt/tls/:ro
    ```

1. **Terminate TLS in front of the container with a reverse proxy**

    Run the container plain on **389** and put a reverse proxy like [Traefik 2.x](https://traefik.io) in front.
    Configure a [Traefik 2.x TCP service](https://docs.traefik.io/routing/services/#configuring-tcp-services) with an
    auto-renewing [Let's Encrypt configuration](https://docs.traefik.io/https/acme/) that forwards the encrypted stream to the container.

    **Traefik 2.x example (TCP mode):**
    ```yaml
    services:
      openldap:
        image: vegardit/openldap:latest
        ports:
          - "389:389"
        environment:
          # ... other options
      labels:
        traefik.enable: "true"
        traefik.tcp.routers.ldap.rule: HostSNI(`ldap.example.com`)
        traefik.tcp.routers.ldap.entryPoints: ldaps636 # expose externally on port 636
        traefik.tcp.routers.ldap.tls.certresolver=lets_encrypt
        traefik.tcp.routers.ldap.service: ldap
        traefik.tcp.services.ldap.loadbalancer.server.port=389

    traefik:
      image: traefik:latest # https://hub.docker.com/_/traefik?tab=tags
      ports:
        - 636:636  # ldaps
      volumes:
        - /etc/traefik/traefik.yml:/traefik.yml:ro
        - /etc/traefik/keystore.json:/keystore.json # holds self-acquired letsencrypt certs
      labels:
        traefik.enable: true
    ```

    ```yaml
    # https://docs.traefik.io/reference/static-configuration/file/
    entryPoints:
      # https://docs.traefik.io/routing/entrypoints/
      ldaps636:
        address: ":636"
    certificatesResolvers:
      # https://docs.traefik.io/https/acme/
      lets_encrypt:
        acme:
          email: info@example.com
          storage: /keystore.json
          tlsChallenge: {}
          #httpChallenge:
          #  entryPoint: http80
    providers:
      docker:
        # https://docs.traefik.io/providers/docker/
        endpoint: "unix:///var/run/docker.sock"
        exposedByDefault: false # ignore containers that don't have a traefik.enable=true label
        watch: true
    ```


### <a name="uidgid"></a>Changing UID/GID of OpenLDAP service user

The UID/GID of the user running the OpenLDAP service can be aligned with the docker host using the environment variables
`LDAP_OPENLDAP_UID` and `LDAP_OPENLDAP_GID`.

During each container start it is verified that the given UID/GID matches the currently effective UID/GID. If not, the UID/GID
of the `openldap` user are changed accordingly and `chown` on `/etc/ldap` and `/var/lib/slapd` is executed before the OpenLDAP service is started.

### <a name="backup"></a>Periodic LDAP Backup

This image automatically generates a daily LDIF export at `2 a.m.` to `/var/lib/ldap/data.ldif`.

The following environment variables can be used to configure the automatic LDAP backup:
```bash
LDAP_BACKUP_TIME='02:00'  # Format is "HH:MM", i.e. 24-hour format with minute precision
LDAP_BACKUP_FILE='/var/lib/ldap/data.ldif'
```

To disable automatic backup set an empty value for the environment variable `LDAP_BACKUP_TIME`.

### <a name="timesync"></a>Synchronizing timezone/time with docker host

To use the same timezone and/or time of the docker host you can run the image with:
```sh
--volume /etc/localtime:/etc/localtime:ro \
--volume /etc/timezone:/etc/timezone:ro
```

Docker compose file example:
```yaml
version: '3.7'
services:
  openldap:
    image: vegardit/openldap:latest
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
```

### <a name="performance-tuning"></a>Performance tuning

#### DB Indexes

The database indexes configured during initial container launch are imported from [/opt/ldifs/init_backend_indexes.ldif](image/ldifs/init_mdb_indexes.ldif).

To use other indexes, mount a custom file at that path **before** initial container launch.

#### Memory usage

The maximum number of open files is set to `1024` by default to prevent excessive RAM consumption as reported [here](https://github.com/docker/docker/issues/8231).

Increase this limit with the following environment variable:

```sh
LDAP_NOFILE_LIMIT=2048
```

### <a name="troubleshooting"></a>Troubleshooting

The slapd service logs to stdout. You can change the active log levels by setting this environment variable:

```sh
LDAP_LOG_LEVELS='Config Stats'
```

Available [log levels](https://www.openldap.org/doc/admin24/slapdconfig.html#loglevel%20%3Clevel%3E):

```
Any     (-1)     enable all debugging
Trace   (1)      trace function calls
Packets (2)      debug packet handling
Args    (4)      heavy trace debugging
Conns   (8)      connection management
BER     (16)     print out packets sent and received
Filter  (32)     search filter processing
Config  (64)     configuration processing
ACL     (128)    access control list processing
Stats   (256)    stats log connections/operations/results
Stats2  (512)    stats log entries sent
Shell   (1024)   print communication with shell backends
Parse   (2048)   print entry parsing debugging
Sync    (16384)  syncrepl consumer processing
None    (32768)  only messages that get logged whatever log level is set
```


## <a name="references"></a>References

- OpenLDAP Software 2.5 Administrator's Guide https://www.openldap.org/doc/admin25/guide.html
- OpenLDAP Online Configuration Reference https://tylersguides.com/guides/openldap-online-configuration-reference/
- `slapd-config(5)` - Linux man page https://linux.die.net/man/5/slapd-config


## <a name="license"></a>License

All files in this repository are released under the [Apache License 2.0](LICENSE.txt).

Individual files contain the following tag instead of the full license text:
```
SPDX-License-Identifier: Apache-2.0
```

This enables machine processing of license information based on the SPDX License Identifiers that are available here: https://spdx.org/licenses/.
