import { App } from 'aws-cdk-lib'
import { ScalingThrottlingStack } from '../lib/stack'

const app = new App()
// Web Functions が使えるリージョン（東京）にデプロイする
new ScalingThrottlingStack(app, 'LambdaWebFunctionsScalingThrottling', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'ap-northeast-1' },
})
