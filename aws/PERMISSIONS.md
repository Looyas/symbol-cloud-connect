# Permissions granted by the stack (aws-v1.0.0)

`<IP>` stands for `"Condition": {"IpAddress": {"aws:SourceIp": [<Symbol egress CIDRs>]}}`.
It is on every *Allow* statement of both Symbol roles when `SymbolEgressCidrs` is set (it
always is in Symbol's links). Each role then also has:

| Statement | Reason |
|---|---|
| `Deny` `*` on `*` when `NotIpAddress aws:SourceIp` = Symbol's CIDRs and `aws:ViaAWSService = false` | Restricts the AWS managed policies too (they cannot carry a condition). Calls AWS services make on Symbol's behalf are not affected. |

## Trust (both roles)

```json
{"Effect": "Allow", "Principal": {"AWS": "<SymbolPrincipalArn>"}, "Action": "sts:AssumeRole",
 "Condition": {"StringEquals": {"sts:ExternalId": "<ExternalId>"}}}
```

`MaxSessionDuration` = 3600 s. IAM rejects the stack if the principal does not exist.

## signin: discovery only

Created only when sign-in is on and `IdentityCenterStartUrl` is empty.

| Object | Permission | Reason |
|---|---|---|
| Role of `SymbolIdcDiscovery-<org>` (trusted by `lambda.amazonaws.com`, `aws:SourceAccount` = your account) | `sso:ListInstances` on `*` | Find the Identity Center instance (Region, identity store id). The action has no resource-level permission. |
| same | `logs:CreateLogStream`, `logs:PutLogEvents` on its own log group | Its logs (`/aws/lambda/SymbolIdcDiscovery-<org>`, 14 days) |

Symbol receives no permission for sign-in. Users get credentials through their own
Identity Center permission sets.

## finops: role `SymbolFinOps-<org>`, policy `symbol-finops`

`<path>` = `<prefix>/<export name>/` (with `CreateFocusExport=true`:
`symbol-focus/symbol-focus-<org>/`).

| Statement | Resource | Reason |
|---|---|---|
| `s3:ListBucket` with `StringLike s3:prefix = <path>*` + `<IP>` | the export bucket | List the export's billing periods and manifests. Neighbouring exports are not listable. |
| `s3:GetBucketLocation` + `<IP>` | the export bucket | Resolve the bucket Region |
| `s3:GetObject` + `<IP>` | `arn:aws:s3:::<bucket>/<path>*` | Read `data/BILLING_PERIOD=…/*.csv.gz` and `metadata/BILLING_PERIOD=…/*-Manifest.json` |
| `tag:GetResources` + `<IP>` | `*` | Tags for cost allocation (no resource-level permission) |
| `cost-optimization-hub:ListEnrollmentStatuses`, `ListRecommendations`, `GetRecommendation` + `<IP>` | `*` | Rightsizing and savings recommendations, enrollment check (no resource-level permission) |
| `organizations:ListAccounts`, `organizations:DescribeOrganization` + `<IP>` | `*` | Account names for member accounts (no resource-level permission) |
| `ec2:DescribeRegions` + `<IP>` | `*` | Regions to inventory (no resource-level permission) |
| `kms:Decrypt` with `kms:ViaService = s3.*.amazonaws.com` + `<IP>` (only if `ExportBucketKmsKeyArn` is set) | that key | Read an SSE-KMS export, through S3 only |

### Data Export (when `CreateFocusExport = true`)

| Object | Setting | Reason |
|---|---|---|
| Bucket `symbol-focus-<account>-<8 hex of the stack id>` | SSE-S3, Block Public Access (all four), *BucketOwnerEnforced*, abort incomplete uploads after 7 days, `DeletionPolicy`/`UpdateReplacePolicy` **Retain** | Your billing data stays yours after Delete stack |
| Bucket policy `DenyInsecureTransport` | Deny `s3:*` when `aws:SecureTransport = false` | TLS only |
| Bucket policy `EnableAWSDataExportsToWriteToS3` | Allow `bcm-data-exports.amazonaws.com`, `billingreports.amazonaws.com` `s3:PutObject` on `<bucket>/*` when `aws:SourceAccount` = your account and `aws:SourceArn` like `arn:aws:cur:us-east-1:<account>:definition/*` or `arn:aws:bcm-data-exports:us-east-1:<account>:export/*` | AWS's documented Data Exports bucket policy. Only exports of your account can write. |
| Bucket policy `EnableAWSDataExportsToCheckBucketPolicy` | Same principals and conditions, `s3:GetBucketPolicy` on the bucket | Lets Data Exports verify the bucket policy and ownership |
| Export `symbol-focus-<org>` | `SELECT <all 48 columns> FROM FOCUS_1_0_AWS`, `TEXT_OR_CSV`, `GZIP`, `CUSTOM`, `OVERWRITE_REPORT`, `SYNCHRONOUS`, prefix `symbol-focus` | What Symbol's FinOps reader parses. In the management account it covers every member account. |

## monitoring: role `SymbolObservability-<org>`, policy `symbol-monitoring`

| Statement | Resource | Reason |
|---|---|---|
| `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `sqs:ChangeMessageVisibility` + `<IP>` | queue `symbol-monitoring-<org>` | Long-poll the events, delete what Symbol stored, check the queue, extend processing time |

| Object | Setting | Reason |
|---|---|---|
| Queue `symbol-monitoring-<org>` | SSE-SQS, retention `MonitoringQueueRetentionSeconds` (default 4 days), visibility 60 s, long polling 20 s, redrive to `…-dlq` after 5 receives | Events wait while Symbol is unreachable; a message Symbol cannot store ends up in the DLQ (14 days) |
| Queue policy | Allow `events.amazonaws.com` `sqs:SendMessage` when `aws:SourceArn` = the Symbol rule; Deny non-TLS | Only the Symbol rule can write |
| Rule `symbol-monitoring-<org>` (default bus, us-east-1) | `detail-type` in `AWS API Call via CloudTrail`, `GuardDuty Finding`, `Security Hub Findings - Imported`, `Config Rules Compliance Change` | The four families Symbol's monitoring service maps. GuardDuty, Security Hub and Config are **not** enabled by the stack; their events flow once you enable them. |

The stack does **not** add a resource policy to the us-east-1 default event bus: events sent
by the forwarders come from the same account, which the default bus already accepts. The
forwarder's IAM role is what authorises them.

### Regional forwarder (`symbol-aws-regional-forwarder.yaml`, one per extra Region)

| Object | Permission | Reason |
|---|---|---|
| Role (generated name), trusted by `events.amazonaws.com` with `aws:SourceArn` = this Region's rule and `aws:SourceAccount` = your account | `events:PutEvents` on `arn:aws:events:us-east-1:<account>:event-bus/default` only | Cross-Region delivery to the main rule |
| Rule `symbol-monitoring-<org>` in the Region | same pattern as above | Forward the Region's events |

## security: managed policies on `SymbolObservability-<org>`

| Policy | Reason |
|---|---|
| `arn:aws:iam::aws:policy/SecurityAudit` | Security configuration metadata (IAM credential report, password policy, trails, encryption settings…) |
| `arn:aws:iam::aws:policy/job-function/ViewOnlyAccess` | Resource lists and descriptions for the CIS checks |

Both are AWS-maintained and read-only. With egress CIDRs, the role's `Deny` restricts them to
Symbol's IPs.

## What the deploying administrator needs

The stack runs with the console user's own permissions (or a CloudFormation service role).
In the management account, in us-east-1, that is roughly:

| Module | Permissions |
|---|---|
| all | `cloudformation:*` on the stack; `iam:CreateRole`, `iam:PutRolePolicy`, `iam:AttachRolePolicy`, `iam:TagRole`, `iam:GetRole`, `iam:PassRole` (discovery role to Lambda), and the matching delete/detach actions for Delete stack |
| signin (detection) | `lambda:CreateFunction`, `lambda:InvokeFunction`, `lambda:TagResource`, `lambda:DeleteFunction`, `logs:CreateLogGroup`, `logs:PutRetentionPolicy`, `logs:DeleteLogGroup` |
| finops | `s3:CreateBucket`, `s3:PutBucket*` (encryption, public access block, ownership, lifecycle, policy, tagging), `bcm-data-exports:CreateExport`, `bcm-data-exports:TagResource`, `bcm-data-exports:DeleteExport`, `cur:PutReportDefinition` (Data Exports authorisation) |
| monitoring | `sqs:CreateQueue`, `sqs:SetQueueAttributes`, `sqs:TagQueue`, `sqs:DeleteQueue`, `events:PutRule`, `events:PutTargets`, `events:RemoveTargets`, `events:DeleteRule`, `events:DescribeRule` |

`AdministratorAccess` covers all of it. The stack needs `CAPABILITY_NAMED_IAM` (fixed role
names); the forwarder needs `CAPABILITY_IAM`.

Service Control Policies can deny any of these actions, or the roles' read actions. Symbol's
checks name the action that was denied.
