// Hono アプリ（app/dist）を 1 つの Web Function（maxConcurrencyPerEnvironment は既定の 64）に載せ、3 つのエンドポイントを付けるスタック
//   prod    … maxEnvironments 10（環境がいくつ立つかを見る）
//   maxenv2 … maxEnvironments 2（環境数の上限で 429 を出す）
//   rate100 … rateLimit 100（毎秒のリクエスト数の上限で 429 を出す）
import * as path from 'node:path'
import { CfnOutput, Fn, RemovalPolicy, Stack, StackProps } from 'aws-cdk-lib'
import * as iam from 'aws-cdk-lib/aws-iam'
import * as lambda from 'aws-cdk-lib/aws-lambda'
import * as logs from 'aws-cdk-lib/aws-logs'
import * as s3 from 'aws-cdk-lib/aws-s3'
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment'
import { Construct } from 'constructs'

const PROJECT = 'lambda-web-functions-scaling-throttling'
const DIST = path.join(__dirname, '../../app/dist')
const MAX_ENVIRONMENTS = 10 // 費用の上限（1 環境 2 vCPU）

export class ScalingThrottlingStack extends Stack {
  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props)

    const suffix = this.node.tryGetContext('bucket_suffix') ?? this.account
    // -c disabled=true で全エンドポイントの rateLimit を 0 にして遮断する（503 Platform.EndpointDisabled）。検証の合間に置いておくとき用
    const disabled = this.node.tryGetContext('disabled') === 'true'
    // -c revision_tag=xxx で、コードと設定は同じまま環境変数だけ違う新しいリビジョンを作る（学習値が引き継がれるかの確認用）
    const revisionTag: string | undefined = this.node.tryGetContext('revision_tag')
    const retention = logs.RetentionDays.ONE_WEEK

    // Web Functions はコードを S3 の .zip から読み、バージョニングが必須
    const bucket = new s3.Bucket(this, 'CodeBucket', {
      bucketName: `${PROJECT}-${suffix}`,
      versioned: true,
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    })
    bucket.addToResourcePolicy(
      new iam.PolicyStatement({
        principals: [new iam.ServicePrincipal('lambda.amazonaws.com')],
        actions: ['s3:GetObject', 's3:GetObjectVersion'],
        resources: [bucket.arnForObjects('*')],
        conditions: {
          ArnLike: { 'aws:SourceArn': `arn:aws:lambda:${this.region}:${this.account}:web-function/${PROJECT}/revision/*` },
        },
      }),
    )
    const code = new s3deploy.BucketDeployment(this, 'Code', {
      sources: [s3deploy.Source.asset(DIST)],
      destinationBucket: bucket,
      extract: false, // .zip のまま置く
    })

    const role = new iam.Role(this, 'WebRole', {
      roleName: `${PROJECT}-web-role`,
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole')],
    })

    const name = PROJECT

    // ロググループ（集約先と .local）は Lambda が既定設定（保持無期限）で作る前に CDK で作っておく
    const logGroup = new logs.LogGroup(this, 'LogGroup', {
      logGroupName: `/aws/lambda/web/${name}`,
      retention,
      removalPolicy: RemovalPolicy.DESTROY,
    })
    const localLogGroup = new logs.LogGroup(this, 'LocalLogGroup', {
      logGroupName: `/aws/lambda/web/${name}.local`,
      retention,
      removalPolicy: RemovalPolicy.DESTROY,
    })

    const fn = new lambda.CfnWebFunction(this, 'WebFunction', { functionName: name })
    const revision = new lambda.CfnWebFunctionRevision(this, 'Revision', {
      functionName: fn.ref,
      buildConfig: {
        runtimeConfig: { runtime: 'nodejs24.x' },
        codeConfig: { s3Object: { bucket: bucket.bucketName, key: Fn.select(0, code.objectKeys) } },
      },
      serviceConfig: {
        executionRoleArn: role.roleArn,
        timeoutSeconds: 60, // 待ち時間の最大 20 秒 + 余裕
        ...(revisionTag ? { environmentVariables: { REVISION_TAG: revisionTag } } : {}),
        // maxConcurrencyPerEnvironment は指定しない（既定の 64）
        // platform.requestComplete（リクエストごとの result / errorType）を出すために DEBUG にする
        telemetryConfig: { loggingConfig: { systemLogLevel: 'DEBUG' } },
      },
    })
    revision.node.addDependency(code, bucket.policy!, logGroup, localLogGroup)

    const makeEndpoint = (endpointName: string, scaling: Record<string, unknown>) => {
      const ep = new lambda.CfnWebFunctionEndpoint(this, `Endpoint${endpointName}`, {
        functionName: fn.ref,
        endpointName,
        endpointType: 'HomeRegion',
        authType: 'ApplicationManaged', // 認証なし。検証が終わったらすぐ destroy する前提
        revisionWeights: [{ revisionId: revision.attrRevisionId, weight: 100 }],
        ...scaling,
        ...(disabled ? { throttleConfig: { rateLimit: 0 } } : {}),
      })
      new CfnOutput(this, `Url${endpointName}`, { value: `https://${ep.attrDomainName}/` })
    }

    makeEndpoint('prod', { scalingConfig: { maxEnvironments: MAX_ENVIRONMENTS } })
    makeEndpoint('maxenv2', { scalingConfig: { maxEnvironments: 2 } })
    makeEndpoint('rate100', { scalingConfig: { maxEnvironments: MAX_ENVIRONMENTS }, throttleConfig: { rateLimit: 100 } })
  }
}
