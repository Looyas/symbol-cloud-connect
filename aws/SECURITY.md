# Security model (AWS)

## Trust boundaries

```
Symbol                                    Your AWS account (management / payer)
------                                    -------------------------------------
generates an ExternalId per org/session   CloudFormation downloads the public template from
(kept in Symbol's Vault)                  Symbol's S3 bucket and runs it with YOUR permissions
publishes: its principal ARN, the         (logged in CloudTrail)
ExternalId, egress IPs  -------------->   creates two read-only roles, a queue, a rule, an
                                          optional Data Export
                                          outputs the connection code: identifiers only
          <----------------------------   you paste it into Symbol
sts:AssumeRole from Symbol's principal
with the ExternalId, from its egress IPs ->  1-hour sessions; permissions apply only from
                                             Symbol's egress IPs
```

- **Public template.** Every resource and permission is in this repository. Review it, or
  create a change set, before you create the stack.
- **No secret crosses the boundary.** No access key is created, downloaded or pasted.
  Symbol authenticates as its own AWS principal and assumes your roles. The connection code
  holds only ARNs, names, a queue URL and an account id. It does not contain the
  ExternalId.
- **No standing admin access.** Both roles are read-only (the only "write" is deleting
  messages from Symbol's own queue, which is how a queue is read). Sign-in uses your users'
  own IAM Identity Center permission sets; the stack grants them nothing.

## The ExternalId

The roles trust Symbol's principal **only** with `sts:ExternalId` equal to your
organisation's value. This is AWS's guard against the
[confused deputy](https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html):
another Symbol customer cannot make Symbol use your roles, because Symbol uses the
ExternalId it holds for *their* organisation, which your trust policy rejects.

- Symbol generates it (40 random characters), stores it in Vault, and never logs it in full.
- It is **not a secret** in AWS's model: it appears in the quick-create link and in the
  stack's parameters. Knowing it is useless without Symbol's principal.
- It is not in the connection code.
- **Rotation:** a new Symbol session issues a new value; *Update stack* with it. The old
  value stops working when the update completes.

## Least privilege

- Two roles, so each identity can be revoked on its own: `SymbolFinOps-<org>` and
  `SymbolObservability-<org>`.
- `MaxSessionDuration` 3600: a session lasts at most one hour.
- Resource-scoped where AWS allows it (the export path, the queue, the KMS key). The
  actions on `Resource: "*"` are those AWS offers no resource-level permission for; they are
  listed in [PERMISSIONS.md](PERMISSIONS.md).
- **Network restriction.** When Symbol publishes egress CIDRs, every *Allow* statement
  carries `IpAddress: aws:SourceIp`, and each role also gets a `Deny *` when the call does
  not come from those CIDRs (`aws:ViaAWSService = false`). The deny is what restricts the
  AWS managed policies `SecurityAudit` and `ViewOnlyAccess`, which cannot carry a condition.
  A stolen session cannot be used from another network.
  - The trust policy itself is not IP-restricted: the condition applies to the calls the
    session makes.
  - `aws:SourceIp` is absent when a request goes through a VPC endpoint. Symbol calls AWS
    over the internet from its published IPs, so this does not apply.
  - Calls an AWS service makes on Symbol's behalf (for example S3 asking KMS to decrypt an
    SSE-KMS object) keep Symbol's source IP
    ([IAM: aws:SourceIp](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html#condition-keys-sourceip)).
- Service principals are scoped: the Data Export can write only into its bucket and only for
  exports of your account (`aws:SourceAccount`, `aws:SourceArn`); EventBridge can send to the
  queue only from the Symbol rule (`aws:SourceArn`); the forwarder role trusts EventBridge
  only for its own rule in your account.
- Encryption and transport: the bucket uses SSE-S3 with Object Ownership
  *BucketOwnerEnforced* and all four Block Public Access settings; queues use SSE-SQS. Bucket
  and queue policies deny non-TLS requests.

## What Symbol can and cannot do

| Symbol can | Symbol cannot |
|---|---|
| Read the FOCUS export files under `<prefix>/<export>/` | Read any other object or bucket |
| List accounts and the organisation, read tags, read Cost Optimization Hub recommendations | Change billing, budgets, accounts, Cost Optimization Hub enrollment |
| Read and delete messages of `symbol-monitoring-<org>` | Send messages, read any other queue, change the rule |
| With `security`: read configuration metadata across services (SecurityAudit, ViewOnlyAccess) | Read data in S3 objects, DynamoDB items, secrets values, or change anything |
| Learn the Identity Center Region and access portal URL | Sign anyone in, create users, change permission sets |

## Integrity of releases

- Templates are published by a GitHub Actions workflow on protected `aws-vX.Y.Z` tags,
  authenticated to AWS through GitHub OIDC (no stored key).
- **Releases are immutable.** Each object is uploaded with `If-None-Match: *`, and the
  bucket policy refuses any `PutObject` without it: an existing version cannot be replaced.
  The bucket is versioned.
- The workflow prints the SHA-256 of each template. connections-service pins it in
  `SETUP_TEMPLATE_REGISTRY.aws` and Symbol's links name an exact version, never `latest`.

To verify a template yourself:

```bash
curl -sO https://symbol-cloud-connect.s3.us-east-1.amazonaws.com/aws/aws-v1.0.0/symbol-aws-stack.yaml
sha256sum symbol-aws-stack.yaml      # compare with the release log / Symbol's registry
git diff --no-index symbol-aws-stack.yaml <checkout of tag aws-v1.0.0>/aws/symbol-aws-stack.yaml
```

## Revocation

- **You:** Delete the stack (and the forwarder stacks). The roles disappear and every
  Symbol session stops at once. Deleting a role alone also works.
- **Symbol:** Disconnect deletes Symbol's rows and Vault secrets, including the ExternalId.

## Reporting a vulnerability

Email **security@symbole.ai** with the details and, if possible, a reproduction. Please do
not open a public issue. We acknowledge within 2 business days. For a confirmed
vulnerability in a released template, we publish a fixed version and mark the affected
version deprecated: Symbol then refuses connection codes from it and prompts customers to
update.
