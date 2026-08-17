# vegardit/openldap <a href="https://github.com/vegardit/docker-openldap/" title="GitHub Repo"><img height="30" src="https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/github.svg?sanitize=true"></a>

[![Build Status](https://github.com/vegardit/docker-openldap/workflows/Build/badge.svg "GitHub Actions")](https://github.com/vegardit/docker-openldap/actions?query=workflow%3ABuild)
[![License](https://img.shields.io/github/license/vegardit/docker-openldap.svg?label=license)](#license)
[![Docker Pulls](https://img.shields.io/docker/pulls/vegardit/openldap.svg)](https://hub.docker.com/r/vegardit/openldap)
[![Docker Stars](https://img.shields.io/docker/stars/vegardit/openldap.svg)](https://hub.docker.com/r/vegardit/openldap)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-v2.1%20adopted-ff69b4.svg)](CODE_OF_CONDUCT.md)

1. [What is it?](#what-is-it)
1. [Configuration](#configuration)
   1. [Initial configuration](#initial-configuration)
   1. [Additional schemas](#additional-schemas)
   1. [Initial LDAP tree](#initial-ldap-tree)
   1. [Configuring the Password Policy](#ppolicy)
   1. [Kerberos authentication (GSSAPI)](#kerberos-authentication)
   1. [Transport Encryption (LDAPS/STARTTLS)](#transport-encryption)
   1. [Syncrepl over LDAPS](#syncrepl-ldaps)
   1. [Changing UID/GID of OpenLDAP service user](#uidgid)
   1. [LDAP Backups](#backup)
   1. [Synchronizing timezone/time with docker host](#timesync)
   1. [Performance tuning](#performance-tuning)
   1. [Troubleshooting](#troubleshooting)
1. [References](#references)
1. [License](#license)


## <a name="what-is-it"></a>What is it?

An opinionated, multi-arch Docker image - currently based on [Debian](https://www.debian.org/)'s [`debian:trixie-slim`](https://hub.docker.com/_/debian/tags?name=trixie-slim) -
built for easy deployment of an [OpenLDAP 2.6](https://www.openldap.org/doc/admin26/) server.

Automatically rebuilt **weekly** to include the latest OS security fixes.

## <a name="configuration"></a>Configuration

### <a name="initial-configuration"></a>Initial configuration

Various parts of the LDAP server can be configured via environment variables. All environment variables starting with `LDAP_INIT_`
are only evaluated on the **first** container launch. Changing their values later has no effect when restarting or updating the container.

The generated ACLs allow anonymous clients to query the Root DSE for server capabilities, but not to read directory entries.
Directory ACLs retain anonymous `auth` access only so clients can bind and establish an identity.
Set `LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE=false` on the first launch to restrict Root DSE reads to authenticated clients. This does not
remove anonymous `auth` access because slapd needs that ACL privilege to verify credentials during a bind. Clients that use Root DSE
data to choose an authentication mechanism must have that mechanism configured explicitly in this mode.

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
LDAP_INIT_ALLOW_ANONYMOUS_ROOT_DSE='true' # if set to false, authentication is required to query the Root DSE
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

#### Supported initialization mounts

These are the supported mounts for bootstrap customization. Persistent volumes, TLS files, and replication secrets are described in their own sections.

| Container target | Purpose | When it is used |
|---|---|---|
| Path set by `INIT_SH_FILE` | Source a shell script that can set image variables | Every container start, before configuration checks |
| `/opt/ldifs/custom-schema/` | Add dynamic-configuration schema LDIFs | First initialization, on every node |
| `/opt/ldifs/custom/` | Add directory data LDIFs | First initialization, except on replication consumers |
| `/opt/ldifs/init_org_tree.ldif` | Replace the initial organization tree | First initialization, except on replication consumers |
| `/opt/ldifs/init_org_entries.ldif` | Replace the initial users and groups | First initialization, except on replication consumers |
| `/opt/ldifs/init_org_ppolicy.ldif` | Replace the initial password policy | First initialization, except on replication consumers |
| `/opt/ldifs/init_mdb_indexes.ldif` | Replace the MDB index settings | First initialization, on every node |

### <a name="additional-schemas"></a>Additional schemas

To add application schemas without replacing the image's built-in files, mount a directory at `/opt/ldifs/custom-schema`:

```sh
docker run -itd \
  -e LDAP_INIT_ROOT_USER_PW='newpassword' \
  -v /path/on/docker/host/schemas:/opt/ldifs/custom-schema:ro \
  vegardit/openldap
```

On the first initialization of new volumes, the image loads every non-hidden `*.ldif` file directly inside this directory.
It loads them after the built-in sudo and OpenSSH schemas, and before database settings or directory data.
Standalone servers, replication providers, and replication consumers all load the schemas because `cn=config` is local to each node.
Restarts and replacement containers that reuse initialized volumes do not load them again.

Filenames are sorted byte by byte in the C locale, not in natural numeric order, so `10.ldif` comes before `2.ldif`.
Use fixed-width prefixes such as `10-guacamole.ldif` and `20-kerberos.ldif` when one schema depends on another.
Each file supports the same `${NAME}` placeholders as the image's built-in LDIFs; an undefined placeholder stops initialization.

Provide schemas as `cn=config` LDIF files. Leave the index out of schema DNs, for example `cn=my-schema,cn=schema,cn=config`, so OpenLDAP can assign its internal `{N}` index.
Older `.schema` files must be converted to LDIF first. Modules and overlays need separate configuration.

Only mount files you trust. The loader uses local SASL EXTERNAL access, which can change all of `cn=config`; it does not inspect each LDIF to ensure it contains only schema entries.
Changes are not transactional: if one file fails, changes made by earlier files remain. Fix the file and retry with clean configuration and data volumes.

### <a name="initial-ldap-tree"></a>Initial LDAP tree

The initial LDAP tree structure is imported from [/opt/ldifs/init_org_tree.ldif](image/ldifs/init_org_tree.ldif).
You can mount a custom file at that path if you need changes.

LDAP entries (users, groups) are imported from [/opt/ldifs/init_org_entries.ldif](image/ldifs/init_org_entries.ldif).
You can mount a custom file at that path if you need changes.

#### Additional initialization LDIFs

To add directory data without replacing the image's LDIFs, mount a directory at `/opt/ldifs/custom`:

```sh
docker run -itd \
  -e LDAP_INIT_ROOT_USER_PW='newpassword' \
  -e CUSTOM_ENTRY_NAME='service-account' \
  -v /path/on/docker/host/ldifs:/opt/ldifs/custom:ro \
  vegardit/openldap
```

When the image initializes clean configuration and data volumes for the first time, it loads every non-hidden `*.ldif` file directly inside this directory.
Files are loaded after the built-in tree, password policy, entries, and replication provider account, and before the initial backup.
Filenames are sorted byte by byte in the C locale rather than in natural numeric order, so `10.ldif` precedes `2.ldif`.
Use fixed-width prefixes such as `10-groups.ldif` and `20-users.ldif` when one file depends on another.

Replication consumers do not load custom LDIFs because syncrepl supplies their directory data.
Restarts and replacement containers that reuse initialized volumes do not load them again.

Each file supports the same `${NAME}` placeholders as the image's built-in LDIFs.
Values can come from container environment variables or values calculated during initialization.
An undefined placeholder stops initialization.
The image processes each file with `ldapmodify -a`: records without `changetype` are added, while explicit RFC 2849 change records use the operation they specify.

Use this directory for entries below the configured organization DN.
Do not use it to change `cn=config`, add schemas, or load modules.
Changes are not transactional: if one file fails, changes made by earlier files remain.
Fix the file and retry with clean configuration and data volumes.

### <a name="ppolicy"></a>Configuring the Password Policy

On **initial** container launch, the [password policy](https://www.openldap.org/doc/admin24/overlays.html#Password%20Policies) is imported from [/opt/ldifs/init_org_ppolicy.ldif](image/ldifs/init_org_ppolicy.ldif).

The following parameters can be modified via environment variables **before** initial container launch:

```sh
LDAP_INIT_PPOLICY_DEFAULT_DN='cn=DefaultPasswordPolicy,ou=Policies,${LDAP_INIT_ORG_DN}'
LDAP_INIT_PPOLICY_PW_MIN_LENGTH=8
LDAP_INIT_PPOLICY_MAX_FAILURES=3
LDAP_INIT_PPOLICY_LOCKOUT_DURATION=300
```

If more customizations are required, simply mount a custom policy file at `/opt/ldifs/init_org_ppolicy.ldif` **before** initial container launch.

#### Password quality checking with PPM

The image installs Debian's [PPM password policy module](https://manpages.debian.org/trixie/slapd-contrib/slapm-ppm.5.en.html) and enables it in the built-in password policy.
No additional setting is required. By default, the image converts `LDAP_PPOLICY_PQCHECKER_RULE=0|01010101` to the following PPM rules:

|Pos. |Value  |Effective Rule
|----:|:-----:|:----------
|0-1  | `0\|` |Use local checking. This prefix is optional.
|2-3  | `01`  |Minimum 1 uppercase character.
|4-5  | `01`  |Minimum 1 lowercase character.
|6-7  | `01`  |Minimum 1 digit.
|8-9  | `01`  |Minimum 1 special character.
|10-..| empty |Allow all characters in passwords.

To keep using the legacy syntax with a custom rule, set the environment variable directly:

```sh
LDAP_PPOLICY_PQCHECKER_RULE='0|01020101@!+-#'
```

Each of the four counts must contain two decimal digits. The special-character class contains printable ASCII punctuation.
Any extra non-whitespace characters after the counts are forbidden in passwords.
PPM does not support the old `1|` broadcast mode. The image rejects this mode instead of silently changing its behavior.

To use native PPM syntax instead, set `LDAP_PPOLICY_PPM_CONFIG`. This setting takes precedence over `LDAP_PPOLICY_PQCHECKER_RULE`.
The image keeps the text unchanged and handles the base64 encoding required by `pwdCheckModuleArg`:

```yaml
services:
  openldap:
    environment:
      LDAP_PPOLICY_PPM_CONFIG: |-
        minQuality 4
        forbiddenChars @
```

`docker run --env-file` does not support multiline values. Use a Compose YAML block as shown above, or load a mounted file from `INIT_SH_FILE`:

```sh
LDAP_PPOLICY_PPM_CONFIG=$(</mnt/ppm.conf)
```

The image passes native PPM directives through unchanged. PPM reads them when a password is changed.

#### Applying PPM settings

On every start, a standalone server or replication provider updates each `pwdPolicyChecker` entry when its ppolicy overlay uses the image-managed PPM or still references pqChecker.

Automatic updates do not use the LDAP administrator password, so you do not need to provide that password on later starts.
When automatic updates are enabled, the image adds two permanent, local-only maintenance ACLs during the first reconciliation, including the initial start of a new volume.
The ACLs are inserted at the start of `olcAccess` on `olcDatabase={1}mdb`:

- Container root over `ldapi:///` can write `entry` and `objectClass`.
  Automatic updates need these attributes to find policies.
  The rule uses `write` instead of `read` so existing add, delete, rename, and object-class operations are not reduced to read-only access.
- The same local identity can write `pwdUseCheckModule` and `pwdCheckModuleArg` on `pwdPolicyChecker` entries.

Both ACLs require the root peercred DN and the local `ldapi:///` socket.
LDAP and LDAPS network clients cannot use them.
The ACLs remain in `cn=config` because automatic policy updates run on every writer start.

An explicit empty value disables automatic updates.
For example, use `LDAP_PPOLICY_PPM_CONFIG: ""` in Compose or `docker run -e LDAP_PPOLICY_PPM_CONFIG=`.
Leaving the variable unset is different: the image uses the default legacy rule.

|Configuration |Behavior
|--------------|--------
|`LDAP_PPOLICY_PPM_CONFIG` is not empty |Apply the native PPM text. This setting takes precedence over the legacy rule.
|`LDAP_PPOLICY_PPM_CONFIG` is empty |Disable automatic updates, even though the image has a nonempty legacy default. On a fresh volume, the built-in policy has no `pwdUseCheckModule` or `pwdCheckModuleArg`.
|`LDAP_PPOLICY_PPM_CONFIG` is unset and `LDAP_PPOLICY_PQCHECKER_RULE` is not empty |Translate the legacy rule to PPM text and apply it.
|`LDAP_PPOLICY_PPM_CONFIG` is unset and `LDAP_PPOLICY_PQCHECKER_RULE` is empty |Disable normal updates. Existing pqChecker configurations are handled as described below.

- Automatic updates leave policy attributes unchanged when the overlay uses another custom password check module.
- Only the ppolicy overlay below the built-in `olcDatabase={1}mdb` is managed.
  Ppolicy overlays on custom databases are ignored.
- The image adds `pwdUseCheckModule: TRUE` only when the attribute is missing.
  An explicit `FALSE` therefore disables PPM for that policy. The image still updates `pwdCheckModuleArg`, so enabling PPM later uses the current configuration.
- Replication consumers do not write policy data; they receive the provider's values through syncrepl.
- Automatic updates support only the image's built-in single-writer replication.
  For a custom multi-provider setup, set `LDAP_PPOLICY_PPM_CONFIG` to an empty value and keep the native PPM attributes consistent through replication.

Setting `LDAP_PPOLICY_PPM_CONFIG` to an empty value stops later automatic updates, but it does not remove an existing `pwdUseCheckModule: TRUE`.
Set that policy attribute to `FALSE` to disable PPM for that policy.
Other password-policy rules remain active.

#### Existing pqChecker configurations

When stored configuration still references `/usr/lib/ldap/pqchecker.so`, startup does the following:

- Replace `olcPPolicyCheckModule` with `/usr/lib/ldap/ppm.so`.
  A compatibility symlink lets slapd start long enough to update the stored configuration; the pqChecker binary is no longer included.
- With an explicitly empty `LDAP_PPOLICY_PPM_CONFIG`, leave existing policy attributes unchanged.
- If `LDAP_PPOLICY_PPM_CONFIG` is unset and `LDAP_PPOLICY_PQCHECKER_RULE` is empty, add the old default rule only where PPM policy attributes are missing.
  Existing native PPM values and explicit `pwdUseCheckModule: FALSE` values remain unchanged.
- Stop startup if an unknown configuration version still references the old path, because its pqChecker arguments cannot safely be used as PPM configuration.

A persisted configuration without a ppolicy overlay is also supported.
During migration from 2.5, the configured PPM settings can still update existing `pwdPolicyChecker` entries, but version migration does not create an overlay.
If an overlay is added later, it remains operator-managed; explicitly set `olcPPolicyCheckModule: /usr/lib/ldap/ppm.so`.

### <a name="kerberos-authentication"></a>Kerberos authentication (GSSAPI)

The image advertises only the `EXTERNAL` and `GSSAPI` SASL mechanisms. It
includes the MIT Kerberos GSSAPI plugin, but it does not create or manage a
Kerberos realm, service principal, keytab, or user-to-DN mapping.

To use GSSAPI:

1. Create a service principal whose hostname matches the LDAP hostname, for
   example `ldap/ldap.example.com@EXAMPLE.COM`, and export it to a keytab.
1. Run the container with that hostname and mount the realm configuration and
   keytab. The keytab must remain readable by the `openldap` service user.

   ```yaml
   services:
     openldap:
       image: vegardit/openldap:latest
       hostname: ldap.example.com
       volumes:
         - ./krb5.conf:/etc/krb5.conf:ro
         - ./ldap.keytab:/etc/krb5.keytab:ro
   ```

   For a keytab at another location, set the standard Kerberos environment
   variable, for example `KRB5_KTNAME=FILE:/run/secrets/ldap/ldap.keytab`.

   `hostname:` sets the container's Kerberos service identity, but does not make
   that name reachable from a client. Ensure `ldap.example.com` resolves and
   routes to the container from the client, for example through a Compose network
   alias or by publishing port 389 on an appropriate host interface and pointing
   DNS there.
1. Install the LDAP and Kerberos client tools plus a Cyrus SASL GSSAPI plugin.
   On Debian-based clients:

   ```sh
   sudo apt-get install krb5-user ldap-utils libsasl2-modules-gssapi-mit
   ```

   The GSSAPI plugin is a separate package on Debian; `ldap-utils` and
   `krb5-user` alone do not make GSSAPI available to `ldapwhoami`.
1. Obtain a ticket on the client and select GSSAPI explicitly:

   ```sh
   kinit alice@EXAMPLE.COM
   ldapwhoami -Q -Y GSSAPI -H ldap://ldap.example.com
   ```

Without an `olcAuthzRegexp`, OpenLDAP uses the authenticated SASL identity such
as `uid=alice,cn=gssapi,cn=auth` directly. Under the image's default ACLs, this
unmapped identity receives the same read permissions as other authenticated
users; separately restricted attributes such as `userPassword` remain
protected. Add a strict mapping when the identity must receive the `self`, group,
or write permissions of an LDAP entry.

Identity mapping rewrites an authenticated identity; it is not an allowlist. If
unmapped principals must not receive the default authenticated-user permissions,
custom ACLs must deny identities below `cn=gssapi,cn=auth` before the generic
`by users read` clauses. See the
[OpenLDAP SASL guide](https://www.openldap.org/doc/admin26/sasl.html) for identity
mapping details; broad regular expressions can map a principal to the wrong LDAP
identity.

### <a name="transport-encryption"></a>Transport Encryption (LDAPS/STARTTLS)

LDAP traffic can be encrypted in **two** complementary ways:

1. **Terminate TLS inside the container** using *static* X.509 certificates:

    * Bind-mount your TLS key material to the container to enable STARTTLS on port 389
    * Optionally enable **LDAPS** as well (TLS-wrapped LDAP port 636)

    |Variable                |Default                       |Description
    |------------------------|------------------------------|-----------
    |`LDAP_TLS_ENABLED`      |`auto`                        |Controls whether TLS features are activated:<br>- `auto` - activate TLS only if the files referenced by `LDAP_TLS_CERT_FILE` and `LDAP_TLS_KEY_FILE` exist (defaults: `/run/secrets/ldap/server.crt` and `/run/secrets/ldap/server.key`)<br>- `true` - always enable TLS; fail startup if certificate or private key is missing<br>- `false` - disable all TLS features; ignore other TLS settings
    |`LDAP_LDAPS_ENABLED`    |`true`                        |*(Only applies if TLS is enabled)*<br>`true` - enable implicit TLS (LDAPS) listener on port 636 (`ldaps://`)
    |`LDAP_TLS_CERT_FILE`    |`/run/secrets/ldap/server.crt`|Path to the server certificate **inside** the container
    |`LDAP_TLS_KEY_FILE`     |`/run/secrets/ldap/server.key`|Path to the matching private key **inside** the container
    |`LDAP_TLS_CA_FILE`      |`/run/secrets/ldap/ca.crt`    |Path to the CA bundle for verifying *peer* certificates
    |`LDAP_TLS_VERIFY_CLIENT`|`try`                         |Client certificate policy (see [`TLSVerifyClient`](https://www.openldap.org/doc/admin26/guide.html#TLSVerifyClient%20%7B%20never%20%7C%20allow%20%7C%20try%20%7C%20demand%20%7D)):<br>- `never` - don't request a client certificate<br>- `allow` - request a client certificate; ignore if missing or invalid<br>- `try` - request a client certificate; reject if invalid (ignore if missing)<br>- `demand` - require a valid client certificate
    |`LDAP_TLS_SSF`          |`128`                         |*(Only applies if TLS is enabled)* Minimum overall **Security Strength Factor** (SSF) required for LDAP operations. Accepted values are integers from `0` through `256`. A positive value rejects operations whose effective transport and authentication strength is lower, including ordinary clear-text connections. `0` removes only the image-managed overall SSF requirement; other administrator-defined `olcSecurity` factors and ACLs still apply. SSF is not a direct TLS cipher-key-size selector. More details here: [OpenLDAP Admin Guide](https://www.openldap.org/doc/admin26/guide.html#Security%20Strength%20Factors)

    `LDAP_TLS_ENABLED=auto` is reevaluated on every start. Use `true` when missing certificate files must stop the container instead of disabling TLS.

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

    Pointing LDAP_TLS_KEY_FILE and LDAP_TLS_CERT_FILE to paths accessible from within the container will automatically enable STARTTLS and LDAPS support.

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
        traefik.tcp.routers.ldap.tls.certresolver: lets_encrypt
        traefik.tcp.routers.ldap.service: ldap
        traefik.tcp.services.ldap.loadbalancer.server.port: 389

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


### <a name="syncrepl-ldaps"></a>Syncrepl over LDAPS

Syncrepl copies LDAP entries between two OpenLDAP servers:

- The **provider** is the source server. Applications make directory changes here.
- The **consumer** is the replica. It connects to the provider and copies its entries.

Both servers run the same image. The image configures one-way replication during their first initialization and makes the consumer read-only.
You write LDAP entries to the provider; the consumer receives a copy and rejects local changes.

The minimum role-specific settings are:

```sh
# Provider
LDAP_INIT_REPLICATION_ROLE=provider
LDAP_TLS_VERIFY_CLIENT=never

# Consumer
LDAP_INIT_REPLICATION_ROLE=consumer
LDAP_INIT_REPLICATION_PROVIDER_URI=ldaps://provider
```

Both nodes must mount the same replication-password secret at `/run/secrets/ldap-replication-password`, or set `LDAP_INIT_REPLICATION_BIND_PASSWORD_FILE` to another readable file.
Use a generated, high-entropy value. The provider deliberately exempts this service account from password lockout so failed authentication attempts cannot lock the account and stop replication.
Mount each node's server certificate and key at the default TLS paths; `LDAP_TLS_ENABLED=auto` enables TLS when both files are present.
The consumer must mount the CA certificate on every start so it can verify the provider.
The provider may omit the CA only when `LDAP_TLS_VERIFY_CLIENT=never`, as above.

Use separate, initially empty config and data volumes for each node. The image skips local sample entries on a consumer so its first synchronization can populate the database.
On a new consumer, the periodic backup worker waits for that first synchronization and does not create `LDAP_BACKUP_FILE` from an empty or partial replica.
Both nodes must use the same organization DN, compatible schemas, and the same effective password-policy DN.
The provider creates `uid=replicator,${LDAP_INIT_ORG_DN}` for its replication account and `cn=ReplicationPasswordPolicy,${LDAP_INIT_ORG_DN}` for that account's non-locking password policy.
Because `uid` and `cn` are unique throughout the organization suffix, custom initialization LDIF must not use `uid: replicator` or `cn: ReplicationPasswordPolicy` on any other entry either.
The provider certificate's Subject Alternative Name (SAN) must match the hostname in `LDAP_INIT_REPLICATION_PROVIDER_URI`.
If applications connect to the consumer over LDAPS, the consumer also needs a certificate whose SAN matches its client-facing hostname.

See the [complete Docker Compose example](example/docker-compose/syncrepl/) for local certificates, startup, and verification commands.

Replication settings are applied only while a new config volume is initialized. Changing the bootstrap variables or secret later does not update the persisted `cn=config`.
OpenLDAP stores the replication password in plaintext in the consumer config volume, so protect that volume accordingly.
For configurations beyond one provider and one read-only consumer, configure `cn=config` directly and leave `LDAP_INIT_REPLICATION_ROLE` unset.
The environment-variable bootstrap supports only strict LDAPS with simple-bind authentication.


### <a name="uidgid"></a>Changing UID/GID of OpenLDAP service user

The UID/GID of the user running the OpenLDAP service can be aligned with the docker host using the environment variables
`LDAP_OPENLDAP_UID` and `LDAP_OPENLDAP_GID`.

During each container start, the image checks the configured UID against the effective UID of the `openldap` user.
It checks the configured GID against the GID of the `openldap` group.
If either value differs, the user UID or group GID is changed and `chown` on `/etc/ldap` and `/var/lib/ldap` is executed before the OpenLDAP service is started.

### <a name="backup"></a>LDAP Backups

The image supports two automatic backup triggers:

- **Initial backup:** On the first start of a server that is not a syncrepl consumer, the image creates an LDIF export after setup is complete. If the export fails, the image retries it on the next start. A consumer skips this backup because its database may still be incomplete.
- **Daily backup:** The image creates an LDIF export at `2 a.m.` by default. On a syncrepl consumer, daily backups begin after the initial refresh is complete.

#### Configuration

Use these environment variables to configure the backup schedule and destination:

```bash
LDAP_BACKUP_TIME='02:00'  # 24-hour "HH:MM" format
LDAP_BACKUP_FILE='/var/lib/ldap/data.ldif'
```

`LDAP_BACKUP_FILE` applies to both initial and daily backups.
Set `LDAP_BACKUP_TIME` to an empty value to disable only the daily backup.

#### Destination requirements

The backup destination must meet these requirements:

- The parent directory must be writable by the effective UID and GID of the `openldap` user. This also applies when you use `LDAP_OPENLDAP_UID`, `LDAP_OPENLDAP_GID`, or a bind mount.
- Other UIDs must not be able to replace entries in the backup path while an export is running. Use a directory controlled by root or `openldap`, or a sticky directory that protects entries owned by `openldap`.
- The filesystem must preserve and report Unix ownership and permission bits. The image requires the private directory to be owned by `openldap` with mode `0700` or `2700`, and its marker and exports with mode `0600`.
- If the destination already exists, the `openldap` user must be allowed to replace its directory entry. For example, a foreign-owned file in a sticky directory such as `/tmp` cannot be replaced even though the directory is writable.
- Mount the parent directory instead of the individual backup file, because Docker does not allow the image to replace a file mount.

#### Atomic publication and storage

Each export is first written below a private directory beside `LDAP_BACKUP_FILE`, such as `.data.ldif.tmp` for the default backup name.
This directory is reserved for the image; do not create it, store other files in it, or mount it separately.
The image validates the directory and all of its contents before removing incomplete exports, including after a container restart.

The private directory must use the same filesystem as `LDAP_BACKUP_FILE`.
The complete export is moved atomically to the configured destination so readers cannot see a partial backup.
If publication would cross filesystems, the export fails and the previous backup remains unchanged.
If `LDAP_BACKUP_FILE` is a symbolic link, the image replaces the link itself and does not write to its target.
The resulting backup is owned by `openldap` and has mode `0600`.

Atomic replacement keeps the previous backup while the next complete export is written.
The destination filesystem must therefore have enough free space for both LDIF files at the same time.
With the default path, this capacity is shared with the live database in `/var/lib/ldap`; use a separately sized backup mount for large directories.

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

The database indexes configured during initial container launch are imported from [/opt/ldifs/init_mdb_indexes.ldif](image/ldifs/init_mdb_indexes.ldif).

To use other indexes, mount a custom file at that path **before** initial container launch.
Custom definitions must retain an equality index for `objectClass`, for example `olcDbIndex: objectClass pres,eq`.
PPM reconciliation searches `pwdPolicyChecker` entries by object class on every writer start; without that index, the search scans the complete directory.

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

- OpenLDAP Software 2.6 Administrator's Guide https://www.openldap.org/doc/admin26/guide.html
- OpenLDAP Online Configuration Reference https://tylersguides.com/guides/openldap-online-configuration-reference/
- `slapd-config(5)` - Linux man page https://linux.die.net/man/5/slapd-config


## <a name="license"></a>License

All files in this repository are released under the [Apache License 2.0](LICENSE.txt).

Individual files contain the following tag instead of the full license text:
```
SPDX-License-Identifier: Apache-2.0
```

This enables machine processing of license information based on the SPDX License Identifiers that are available here: https://spdx.org/licenses/.
