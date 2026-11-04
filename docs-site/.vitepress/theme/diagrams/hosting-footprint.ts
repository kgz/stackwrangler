import type { SwDiagram } from './types'

/** Grey-rose bands — match completeness progress CSS. */
const C = {
  workingFill: '#6a9e7f',
  partialFill: '#b48aa0',
  stubFill: '#8a7a70',
  sidecarFill: '#4a4644',
  label: '#f5f1ee',
  stroke: '#1a1817',
  hullWorking: 'rgba(106, 158, 127, 0.18)',
  hullPartial: 'rgba(180, 138, 160, 0.18)',
  hullStub: 'rgba(138, 122, 112, 0.18)',
  hullStrokeWorking: 'rgba(106, 158, 127, 0.55)',
  hullStrokePartial: 'rgba(180, 138, 160, 0.55)',
  hullStrokeStub: 'rgba(138, 122, 112, 0.55)',
  edge: '#8a8580',
  headerFill: '#2c2928',
} as const

function service(
  id: string,
  label: string,
  x: number,
  y: number,
  fill: string,
  w: number,
  h: number,
) {
  return {
    id,
    style: {
      x,
      y,
      size: [w, h],
      labelText: label,
      labelFill: C.label,
      labelFontSize: 12,
      labelFontWeight: 560,
      labelPlacement: 'center' as const,
      labelWordWrap: true,
      labelMaxWidth: w - 16,
      fill,
      stroke: C.stroke,
      lineWidth: 1,
      radius: 8,
      shadowColor: 'rgba(0,0,0,0.25)',
      shadowBlur: 8,
      shadowOffsetY: 2,
    },
  }
}

function header(id: string, label: string, x: number, y: number, w: number) {
  return {
    id,
    style: {
      x,
      y,
      size: [w, 36],
      labelText: label,
      labelFill: C.label,
      labelFontSize: 13,
      labelFontWeight: 650,
      labelPlacement: 'center' as const,
      fill: C.headerFill,
      stroke: C.stroke,
      lineWidth: 1,
      radius: 8,
    },
  }
}

function sidecar(id: string, label: string, x: number, y: number, w = 132) {
  return service(id, label, x, y, C.sidecarFill, w, 30)
}

/**
 * Hosting footprint — three honesty bands + real sidecars.
 * Register siblings in index.ts for more OSS server diagrams.
 */
export const hostingFootprint: SwDiagram = {
  id: 'hosting-footprint',
  title: 'Hosting footprint',
  height: 520,
  background: '#1f1d1c',
  plugins: [
    {
      type: 'hull',
      key: 'band-working',
      members: ['hdr-working', 's3', 'lambda', 'msg', 'iac', 'iam', 'seaweed'],
      padding: 22,
      corner: 'rounded',
      fill: C.hullWorking,
      stroke: C.hullStrokeWorking,
      lineWidth: 1.5,
    },
    {
      type: 'hull',
      key: 'band-partial',
      members: [
        'hdr-partial',
        'ecs',
        'xfer',
        'rds',
        'net',
        'apigw',
        'registry',
        'sftp',
        'pg',
      ],
      padding: 22,
      corner: 'rounded',
      fill: C.hullPartial,
      stroke: C.hullStrokePartial,
      lineWidth: 1.5,
    },
    {
      type: 'hull',
      key: 'band-stub',
      members: ['hdr-stub', 'batch', 'empty', 'bl'],
      padding: 22,
      corner: 'rounded',
      fill: C.hullStub,
      stroke: C.hullStrokeStub,
      lineWidth: 1.5,
    },
  ],
  data: {
    nodes: [
      header('hdr-working', 'Working / strong Partial', 190, 36, 220),
      service('s3', 'S3 UI + objects', 190, 110, C.workingFill, 180, 44),
      service('lambda', 'Lambda', 190, 175, C.workingFill, 180, 40),
      service(
        'msg',
        'SQS · SNS · EB · DDB\nSFN · Kinesis',
        190,
        255,
        C.workingFill,
        180,
        52,
      ),
      service('iac', 'TF / CDK / SAM', 190, 335, C.workingFill, 180, 40),
      service('iam', 'IAM / STS on', 190, 400, C.workingFill, 180, 40),
      sidecar('seaweed', 'SeaweedFS :8333', 40, 110, 118),

      header('hdr-partial', 'Partial · data plane gaps', 480, 36, 240),
      service('ecs', 'ECS / EC2 / ECR', 460, 110, C.partialFill, 190, 44),
      service('xfer', 'Transfer · SFTP', 460, 185, C.partialFill, 190, 40),
      service('rds', 'RDS · DB sidecar', 460, 255, C.partialFill, 190, 40),
      service('net', 'VPC / ELBv2 / SG / R53', 460, 325, C.partialFill, 190, 40),
      service('apigw', 'API Gateway', 460, 395, C.partialFill, 190, 40),
      sidecar('registry', 'distribution/registry', 700, 100, 148),
      sidecar('sftp', 'atmoz/sftp', 700, 185, 120),
      sidecar('pg', 'Postgres / MySQL', 700, 255, 132),

      header('hdr-stub', 'Control plane / chrome / backlog', 920, 36, 250),
      service(
        'batch',
        'Batch / Beanstalk\nApp Runner',
        920,
        140,
        C.stubFill,
        200,
        52,
      ),
      service(
        'empty',
        'S3 specialty / Lens\nAccess Points',
        920,
        240,
        C.stubFill,
        200,
        52,
      ),
      service(
        'bl',
        'EKS · ElastiCache · SES\nCognito · CloudFront',
        920,
        340,
        C.stubFill,
        200,
        52,
      ),
    ],
    edges: [
      {
        id: 'e-s3-sw',
        source: 's3',
        target: 'seaweed',
        style: { stroke: C.edge, lineWidth: 1.5 },
      },
      {
        id: 'e-ecs-reg',
        source: 'ecs',
        target: 'registry',
        style: { stroke: C.edge, lineWidth: 1.5, lineDash: [5, 4] },
      },
      {
        id: 'e-xfer-sftp',
        source: 'xfer',
        target: 'sftp',
        style: { stroke: C.edge, lineWidth: 1.5, lineDash: [5, 4] },
      },
      {
        id: 'e-rds-pg',
        source: 'rds',
        target: 'pg',
        style: { stroke: C.edge, lineWidth: 1.5, lineDash: [5, 4] },
      },
    ],
  },
}
