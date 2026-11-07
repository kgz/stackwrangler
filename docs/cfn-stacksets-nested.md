# CloudFormation StackSets + nested stacks — honesty (#95)

Console chrome for **StackSets** list and **nested stack** navigation. Depth is **Partial**.

## StackSets

| Surface | Status |
|---------|--------|
| Console list `/cloudformation/stacksets` | **Working** chrome — calls `ListStackSets` |
| Create / Delete / detail | **Not wired** (`disabled` + `title="To implement"`) |
| LocalEmu `CreateStackSet` | Returns a `StackSetId` |
| LocalEmu `ListStackSets` / `DescribeStackSet` | Often **empty / not found** after create — store write and list path do not match |

Do not treat a green CreateStackSet CLI call as proof the set is listable. Empty list in the console is the honest LocalEmu outcome today.

## Nested stacks

| Surface | Status |
|---------|--------|
| Stack info **Parent stack** / **Root stack** links | **Working** when `ParentId` / `RootId` are present on `DescribeStacks` |
| Resources: `AWS::CloudFormation::Stack` → child stack | **Working** when `PhysicalResourceId` is a stack ARN/name |
| List row “· nested” marker | **Working** when `ParentId` is set on `ListStacks` |
| Creating nested stacks (`AWS::CloudFormation::Stack` + `TemplateURL`) | **Limited** on LocalEmu — nested create often fails (`TemplateBody` rejected; S3 `TemplateURL` unreliable across dual S3 backends) |

Parent/Root fields show `—` for ordinary root stacks. Nested navigation lights up when the emulator populates those IDs.

## Related

- Console stacks list/detail (pre-#95)
- Write UI: Create [#93](https://github.com/kgz/awsl/issues/93), Update/change sets [#94](https://github.com/kgz/awsl/issues/94)
- Status: [status.md](status.md) · OD mocks: `design/stackwrangler-console/screens/cloudformation-stacksets*.html`
- Drift / stack notifications: Debt [#564](https://github.com/kgz/stackwrangler/issues/564) (from [#147](https://github.com/kgz/awsl/issues/147))

