# S3 parity — profile `local`

Generated: 2026-10-18T13:48:42+10:00  ·  prefix `awsbox-parity-1792295322`

| Check | Result | Detail |
|-------|--------|--------|
| `s3 mb` | pass |  |
| `s3 ls (root)` | pass |  |
| `s3 cp upload` | pass |  |
| `s3 ls bucket` | pass |  |
| `s3 cp download` | pass |  |
| `s3 cp copy` | pass |  |
| `s3 mv` | pass |  |
| `s3 rm object` | pass |  |
| `s3 sync up` | pass |  |
| `s3 sync down` | pass |  |
| `s3 presign` | pass |  |
| `s3 rb --force` | pass |  |
| `s3api create-bucket` | pass |  |
| `s3api put-object` | pass |  |
| `s3api head-object` | pass |  |
| `s3api get-object` | pass |  |
| `s3api list-objects-v2` | pass |  |
| `s3api delete-object` | pass |  |
| `s3api head-bucket` | pass |  |
| `s3api delete-bucket` | pass |  |
| `s3api create-bucket (multipart)` | pass |  |
| `s3api multipart` | pass |  |
| `s3 rb multipart bucket` | pass |  |

**Summary:** pass=23 fail=0 gap=0
