import { BlockDeviceVolume, EbsDeviceVolumeType } from "@aws-cdk/aws-autoscaling";
import { Peer } from "@aws-cdk/aws-ec2";
import type { App } from "@aws-cdk/core";
import { GuUserData } from "@guardian/cdk/lib/constructs/autoscaling";
import { AppIdentity } from "@guardian/cdk/lib/constructs/core/identity";
import type { GuStackProps } from "@guardian/cdk/lib/constructs/core/stack";
import { GuStack } from "@guardian/cdk/lib/constructs/core/stack";
import {
  GuAllowPolicy,
  GuAssumeRolePolicy,
  GuDynamoDBReadPolicy,
  GuGetS3ObjectsPolicy,
} from "@guardian/cdk/lib/constructs/iam";
import { AccessScope, GuPlayApp } from "@guardian/cdk";
import { Duration } from "@aws-cdk/core";

export class PrismStack extends GuStack {
  private static app: AppIdentity = {
    app: "prism",
  };

  constructor(scope: App, id: string, props: GuStackProps) {
    super(scope, id, props);

    /*
    Looks like some @guardian/cdk constructs are not applying the App tag.
    I suspect since https://github.com/guardian/cdk/pull/326.
    Until that is fixed, we can safely, manually apply it to all constructs in tree from `this` as it's a single app stack.
    TODO: remove this once @guardian/cdk has been fixed.
     */
    AppIdentity.taggedConstruct(PrismStack.app, this);

    const app = new GuPlayApp(this, {
      ...PrismStack.app,
      userData: new GuUserData(this, {
        ...PrismStack.app,
        distributable: {
          fileName: "prism.deb",
          executionStatement: `dpkg -i /${PrismStack.app.app}/prism.deb`,
        },
      }).userData.render(),
      certificateProps: {
        CODE: { domainName: "prism.code.dev-gutools.co.uk" },
        PROD: { domainName: "prism.gutools.co.uk" },
      },
      monitoringConfiguration: { noMonitoring: true },
      access: { scope: AccessScope.RESTRICTED, cidrRanges: [Peer.ipv4("10.0.0.0/8")] },
      roleConfiguration: {
        additionalPolicies: [
          new GuAllowPolicy(this, "DescribeEC2BonusPolicy", {
            resources: ["*"],
            actions: ["EC2:Describe*"],
          }),
          new GuDynamoDBReadPolicy(this, "ConfigPolicy", { tableName: "config-deploy" }),
          new GuGetS3ObjectsPolicy(this, "DataPolicy", {
            bucketName: "prism-data",
          }),
          new GuAssumeRolePolicy(this, "CrawlerPolicy", {
            resources: ["arn:aws:iam::*:role/*Prism*", "arn:aws:iam::*:role/*prism*"],
          }),
        ],
      },
      accessLogging: { enabled: false, prefix: `ELBLogs/${this.stack}/${PrismStack.app.app}/${this.stage}` },
      scaling: {
        CODE: { minimumInstances: 1 },
        PROD: { minimumInstances: 2 },
      },
      blockDevices: [
        {
          deviceName: "/dev/sda1",
          volume: BlockDeviceVolume.ebs(8, {
            volumeType: EbsDeviceVolumeType.GP2,
          }),
        },
      ],
    });

    app.targetGroup.configureHealthCheck({
      path: "/management/healthcheck",
      unhealthyThresholdCount: 10,
      interval: Duration.seconds(5),
      timeout: Duration.seconds(3),
    });
  }
}
