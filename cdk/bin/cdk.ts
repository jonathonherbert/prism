// This file was autogenerated when creating prism.ts using @guardian/cdk-cli
// It is a starting point for migration to CDK *only*. Please check the output carefully before deploying

import "source-map-support/register";
import { App } from "@aws-cdk/core";
import { Prism } from "../lib/prism";

const app = new App();
new Prism(app, "Prism", { app: "deploy" });
