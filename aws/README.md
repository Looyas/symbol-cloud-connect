# Symbol Cloud Connect for AWS

Public **CloudFormation** template that connects an AWS account to Symbol. You run it in your
own AWS console, with your own credentials. Symbol never gets an access key or an
administrator credential. Only public values go in: Symbol's principal ARN, an ExternalId and
Symbol's egress IPs. Only identifiers come out: the **connection code**.

| Module | What the stack creates | Used by Symbol for |
|---|---|---|
| `signin` | Nothing that grants access. A read-only function (`SymbolIdcDiscovery-<org>`) finds your IAM Identity Center Region and access portal URL, unless you type them in | Users sign in to Symbol with IAM Identity Center and act with **their own** permission sets |
| `finops` | Role `SymbolFinOps-<org>`. Optionally a bucket `symbol-focus-<account>-<id>` and a **FOCUS 1.0** Data Export `symbol-focus-<org>` (CSV, gzip) | Cost and usage, tags, Cost Optimization Hub recommendations, account names |
| `monitoring` | Role `SymbolObservability-<org>`, SQS queue `symbol-monitoring-<org>` (+ `-dlq`), EventBridge rule `symbol-monitoring-<org>` | CloudTrail, GuardDuty, Security Hub and Config events |
| `security` | AWS managed policies `SecurityAudit` and `ViewOnlyAccess` on `SymbolObservability-<org>` | Security posture (CIS) scan |

The roles trust **one** principal, Symbol's, and only with your organisation's
**ExternalId**. When Symbol publishes egress IPs, every permission of the roles works only
from them. Every permission is listed in [PERMISSIONS.md](PERMISSIONS.md); the trust model is
in [SECURITY.md](SECURITY.md).

## How you get here

1. In Symbol, go to **Administration > Cloud configuration > AWS > Configure**, pick the
   modules and choose **Automatic**.
2. Symbol creates a setup session and an ExternalId, then shows **Open AWS CloudFormation
   (us-east-1)**. The link is a CloudFormation *quick-create* link:
   ```
   https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate
     ?templateURL=https://<symbol bucket>.s3.us-east-1.amazonaws.com/aws/aws-vX.Y.Z/symbol-aws-stack.yaml
     &stackName=Symbol-Cloud-Connect-<org>
     &param_SymbolOrgId=…&param_SetupSessionId=…&param_TemplateVersion=aws-vX.Y.Z
     &param_SymbolPrincipalArn=…&param_ExternalId=…&param_SymbolEgressCidrs=…
     &param_EnableSignin=…&param_EnableFinops=…&param_EnableMonitoring=…&param_EnableSecurity=…
   ```
   It contains no secret. The ExternalId is not a secret in AWS's model (see SECURITY.md).

## Running the stack

1. Sign in to the **management (payer) account** of your AWS Organization. FinOps needs it:
   a Data Export created there covers every member account. (An account outside any
   Organization works too.)
2. Stay in **US East (N. Virginia) `us-east-1`**. The stack refuses any other Region: Data
   Exports and the events of global services (IAM, STS, console sign-in) exist only there.
3. Check the **Template URL** shown at the top: it must be on Symbol's bucket, under
   `aws/aws-vX.Y.Z/`.
4. Review the parameters:
   - *Symbol (pre-filled - do not change)*: if you change one, Symbol rejects the code.
   - *Modules*: as chosen in Symbol.
   - *Sign-in*: leave both fields empty to detect them. If your access portal uses a custom
     alias and you want that URL, enter the Region **and** the URL.
   - *FinOps*: keep `CreateFocusExport = true`, or set it to `false` and name an existing
     export. An existing export must be **FOCUS 1.0, CSV, gzip** (Symbol does not read
     Parquet). Enter its prefix without a trailing `/`. If its bucket uses SSE-KMS, give the
     key ARN.
   - *Monitoring*: how long events wait if Symbol cannot read them (default 4 days).
5. Tick **I acknowledge that AWS CloudFormation might create IAM resources with custom
   names** (`CAPABILITY_NAMED_IAM`). This is the consent point: the roles have fixed names so
   that Symbol can check them.
6. **Create stack**. Teams that review a diff first can use **Create change set**.
   It takes about two minutes.
7. **Outputs** tab: copy **SymbolConnectionCode** (`SYMBOL-AWS-1.…`) and paste it into
   Symbol. **SymbolConnectionSummary** says the same in plain words.
8. Symbol assumes each role with the session's ExternalId and runs its checks. The first
   FOCUS delivery can take **up to 24 hours**: until then FinOps shows *waiting for first
   export*, not an error.

### Sign-in detection

When `IdentityCenterStartUrl` is empty, a custom resource runs an inline Python 3.13 function
once (at create, and again when a new Symbol session updates the stack). It calls
`sso-admin:ListInstances` in each Region where IAM Identity Center is offered, with short
timeouts, and returns the Region and `https://<IdentityStoreId>.awsapps.com/start`. Regions
you have not enabled are skipped. It **never fails the stack**: if nothing is found it
returns a *problem* text that Symbol shows you, and you can update the stack with the two
values typed in. Its role can only list Identity Center instances and write its own logs
(kept 14 days). Your users' access is unchanged: they keep their own permission sets.

### Other Regions (monitoring)

EventBridge rules are regional. The main stack's rule sees **us-east-1** events, which
include every global-service event (IAM, STS, sign-in). For each other Region where you run
workloads, create the **regional forwarder** stack there:

- Output **RegionalForwarderQuickCreateUrl** opens it pre-filled; switch the console to the
  target Region first (the forwarder refuses us-east-1).
- Or use **RegionalForwarderTemplateUrl** with `SymbolOrgId` and `TargetEventBusArn` (output
  **MonitoringEventBusArn**).

The forwarder creates one rule with the same pattern and the IAM role EventBridge needs to
`events:PutEvents` on the us-east-1 default bus. It needs `CAPABILITY_IAM`. Forwarded
events arrive unchanged, so the main rule delivers them to Symbol's queue. Events forwarded
between Regions are billed by EventBridge as custom events.

## Updating

When Symbol shows *Update available*, it creates a new session and link. In CloudFormation,
select the stack, **Update > Replace current template**, paste the new template URL, keep
the parameters except those Symbol's link changes (`SetupSessionId`, `TemplateVersion`, and
`ExternalId` on a rotation), review the change set, then **Submit**. Copy the new
**SymbolConnectionCode** into Symbol. Releases are immutable and listed in
[CHANGELOG.md](CHANGELOG.md).

Updating with a new ExternalId cuts the old one at once: Symbol switches after its
AssumeRole with the new value succeeds.

## Revoking access (Delete stack)

1. In Symbol, **Disconnect** (it removes Symbol's rows and secrets).
2. In CloudFormation, **Delete** the main stack and every forwarder stack.

The roles, the queues, the rules and the discovery function are deleted, so Symbol loses
access at once. **The export bucket is retained** (`DeletionPolicy: Retain`) because it holds
your billing data. Delete the Data Export's files and the bucket yourself if you no longer
need them; the Data Export itself is deleted with the stack.

Symbol's daily health check then marks the integration **Revoked**.

## Repository layout

```
aws/
  symbol-aws-stack.yaml               main stack (us-east-1, management account)
  symbol-aws-regional-forwarder.yaml  one per extra Region (monitoring)
  tests/                              offline tests: cfn-lint, structure, connection code
                                      rendering, discovery function, cfn-guard rules
.github/workflows/aws-ci.yml          lint + tests on pull requests
.github/workflows/aws-release.yml     on tag aws-v*: lint, tests, upload to S3, SHA-256
```

Local checks (Python 3.12+):

```bash
cd aws/tests
python -m venv .venv && . .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cfn-lint --include-checks I -- ../symbol-aws-stack.yaml ../symbol-aws-regional-forwarder.yaml
pytest -q                                          # set CFN_GUARD=/path/to/cfn-guard to add the guard tests
```

The tests resolve the templates' intrinsic functions for every module combination, decode
the connection code and compare it with the contract field by field. When the DAAS
repository sits next to this one, they also check the event pattern against
monitoring-service and the export path against connections-service.

## Publishing (Symbol maintainers)

CloudFormation quick-create needs the template on **S3**. One-time setup in Symbol's AWS
account:

1. **Bucket** (for example `symbol-cloud-connect`, in us-east-1): versioning **enabled**,
   SSE-S3, Object Ownership *BucketOwnerEnforced*. Turn off *Block public access* only for
   bucket policies (`BlockPublicPolicy=false`, `RestrictPublicBuckets=false`; keep both ACL
   settings on).
2. **Bucket policy**: public read of `aws/*` only, and no overwrite even for the publisher:
   ```json
   {"Version": "2012-10-17", "Statement": [
     {"Sid": "PublicReadTemplates", "Effect": "Allow", "Principal": "*",
      "Action": "s3:GetObject", "Resource": "arn:aws:s3:::symbol-cloud-connect/aws/*"},
     {"Sid": "NoOverwrite", "Effect": "Deny", "Principal": "*", "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::symbol-cloud-connect/aws/*",
      "Condition": {"Null": {"s3:if-none-match": "true"}}},
     {"Sid": "TlsOnly", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
      "Resource": ["arn:aws:s3:::symbol-cloud-connect", "arn:aws:s3:::symbol-cloud-connect/*"],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}}]}
   ```
3. **GitHub OIDC**: IAM identity provider `token.actions.githubusercontent.com` (audience
   `sts.amazonaws.com`) and a role, for example `symbol-cloud-connect-release`, trusted only
   for tags of this repository:
   ```json
   {"Effect": "Allow", "Principal": {"Federated": "arn:aws:iam::<SYMBOL>:oidc-provider/token.actions.githubusercontent.com"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
                  "StringLike": {"token.actions.githubusercontent.com:sub": "repo:Looyas/symbol-cloud-connect:ref:refs/tags/aws-v*"}}}
   ```
   Its only permission: `s3:PutObject` on `arn:aws:s3:::symbol-cloud-connect/aws/*`.
4. **Repository variables** (Settings > Variables): `SYMBOL_TEMPLATES_BUCKET`,
   `SYMBOL_TEMPLATES_REGION` (us-east-1) and `SYMBOL_RELEASE_ROLE_ARN`. Protect `aws-v*` tags.

The base URL in the template's `Mappings: Symbol.Release.TemplatesBaseUrl` must be
`https://<bucket>.s3.<region>.amazonaws.com/aws`: the release refuses to publish otherwise.

A release: bump `TemplateVersion`'s default and the version in both descriptions, add the
CHANGELOG entry, merge, then push the tag `aws-vX.Y.Z`. The workflow uploads
`aws/aws-vX.Y.Z/symbol-aws-stack.yaml` and `…/symbol-aws-regional-forwarder.yaml` with
`If-None-Match: *` (an existing object makes it fail) and prints both SHA-256 values. Put
them, with `artifact_url` and `forwarder_url`, in connections-service's
`SETUP_TEMPLATE_REGISTRY.aws`.
