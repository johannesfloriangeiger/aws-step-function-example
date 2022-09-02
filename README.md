# AWS Step Function example

## Setup

```
PROFILE=...
aws configure --profile $PROFILE
```

```
FIRST_BUCKET=...
SECOND_BUCKET=...
THIRD_BUCKET=...
```

## Install

### Terraform

Install the Terraform scripts:

```
AWS_SDK_LOAD_CONFIG=1 AWS_PROFILE=$PROFILE terraform -chdir=terraform init
AWS_SDK_LOAD_CONFIG=1 AWS_PROFILE=$PROFILE terraform -chdir=terraform apply --var first-bucket=$FIRST_BUCKET --var second-bucket=$SECOND_BUCKET --var third-bucket=$THIRD_BUCKET
```

Add the file `chunk.txt` to the first and second bucket:

```
echo -n "Hello" | aws s3 cp --profile $PROFILE - s3://$FIRST_BUCKET/chunk.txt
echo -n "World" | aws s3 cp --profile $PROFILE - s3://$SECOND_BUCKET/chunk.txt
```

Deploy the Lambda:

```
echo "exports.handler = async (event) => {
    return event.tokens.join(' ')
};" > index.js && zip lambda.zip index.js

aws --profile $PROFILE lambda update-function-code --function-name concat --zip-file fileb://lambda.zip --publish

rm index.js lambda.zip
```

### Manual

#### Buckets 

Create the first bucket and add the file `chunk.txt`:

```
aws --profile $PROFILE s3 mb s3://$FIRST_BUCKET
echo -n "Hello" | aws s3 cp --profile $PROFILE - s3://$FIRST_BUCKET/chunk.txt
```

Create the second bucket and add the file `chunk.txt`:

```
aws --profile $PROFILE s3 mb s3://$SECOND_BUCKET
echo -n "World" | aws s3 cp --profile $PROFILE - s3://$SECOND_BUCKET/chunk.txt
```

Create the third bucket:

```
aws --profile $PROFILE s3 mb s3://$THIRD_BUCKET
```

#### Roles

##### State machine

Create the basic role for the state machine:

```
CONCAT_ROLE_ARN=$(aws --profile $PROFILE iam create-role --role-name Concat --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "states.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}' | jq -r '.Role.Arn')
```

Attach the policy to allow the execution of lambdas to the state machine role:

```
aws --profile $PROFILE iam attach-role-policy --role-name Concat --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaRole
```

Create a policy to allow reading the chunks from the first two buckets and attach it to the state machine role:

```
READ_POLICY_ARN=$(aws --profile $PROFILE iam create-policy --policy-name ConcatReadPolicy --policy-document '{   
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject"
            ],
            "Resource": [
                "arn:aws:s3:::'$FIRST_BUCKET'/chunk.txt",
                "arn:aws:s3:::'$SECOND_BUCKET'/chunk.txt"
            ]
        }
    ]
}' | jq -r '.Policy.Arn')

aws --profile $PROFILE iam attach-role-policy --role-name Concat --policy-arn $READ_POLICY_ARN
```

Create a policy to allow writing the result into the third bucket and attach it to the state machine role:

```
WRITE_POLICY_ARN=$(aws --profile $PROFILE iam create-policy --policy-name ConcatWritePolicy --policy-document '{   
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject"
            ],
            "Resource": [
                "arn:aws:s3:::'$THIRD_BUCKET'/result.txt"
            ]
        }
    ]
}' | jq -r '.Policy.Arn')

aws --profile $PROFILE iam attach-role-policy --role-name Concat --policy-arn $WRITE_POLICY_ARN
```

##### Lambda

Create the basic role for the lambda:

```
LAMBDA_ROLE_ARN=$(aws --profile $PROFILE iam create-role --role-name Lambda --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "lambda.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}' | jq -r '.Role.Arn')
```

#### Lambda

Create a lambda that returns a simple concatenation of the parameter list `tokens`:

```
echo "exports.handler = async (event) => {
    return event.tokens.join(' ')
};" > index.js && zip lambda.zip index.js

LAMBDA_ARN=$(aws --profile $PROFILE lambda create-function --function-name Concat --role $LAMBDA_ROLE_ARN --runtime nodejs12.x --zip-file fileb://lambda.zip --handler index.handler | jq -r '.FunctionArn')

rm index.js lambda.zip
```

#### State machine

Create the state machine:

```
aws --profile $PROFILE stepfunctions create-state-machine --name Concat --role-arn $CONCAT_ROLE_ARN --definition '{      
  "Comment": "Example of a simple state machine",
  "StartAt": "Parallel",
  "States": {
    "Parallel": {
      "Type": "Parallel",
      "Branches": [
        {
          "StartAt": "Read first chunk",
          "States": {
            "Read first chunk": {
              "Type": "Task",
              "End": true,
              "Parameters": {
                "Bucket": "'$FIRST_BUCKET'",
                "Key": "chunk.txt"
              },
              "Resource": "arn:aws:states:::aws-sdk:s3:getObject",
              "ResultSelector": {
                "Body.$": "$.Body"
              }
            }
          }
        },
        {
          "StartAt": "Read second chunk",
          "States": {
            "Read second chunk": {
              "Type": "Task",
              "End": true,
              "Parameters": {
                "Bucket": "'$SECOND_BUCKET'",
                "Key": "chunk.txt"
              },
              "Resource": "arn:aws:states:::aws-sdk:s3:getObject",
              "ResultSelector": {
                "Body.$": "$.Body"
              }
            }
          }
        }
      ],
      "Next": "Map",
      "ResultPath": "$.Body"
    },
    "Map": {
      "Type": "Pass",
      "Parameters": {
        "tokens.$": "States.Array($.Body[0].Body, $.Body[1].Body, $.Suffix)"
      },
      "Next": "Reduce"
    },
    "Reduce": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "OutputPath": "$.Payload",
      "Parameters": {
        "Payload.$": "$",
        "FunctionName": "'$LAMBDA_ARN':$LATEST"
      },
      "Retry": [
        {
          "ErrorEquals": [
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException"
          ],
          "IntervalSeconds": 2,
          "MaxAttempts": 6,
          "BackoffRate": 2
        }
      ],
      "Next": "Write"
    },
    "Write": {
      "Type": "Task",
      "End": true,
      "Parameters": {
        "Body.$": "$",
        "Bucket": "'$THIRD_BUCKET'",
        "Key": "result.txt"
      },
      "Resource": "arn:aws:states:::aws-sdk:s3:putObject"
    }
  }
}'
```

First, the `chunk.txt` from the first two buckets are read and their content is passed on. Then, the chunks and a suffix are transformed into a list of tokens and passed to the lambda that concatenates them into a string. Finally, that string is written to the third bucket into the file `result.txt`.


## Test

Start the execution and query for its status:

```
STATE_MACHINE_ARN=$(aws --profile $PROFILE stepfunctions list-state-machines | jq -r '.stateMachines[0].stateMachineArn')
EXECUTION_ARN=$(aws --profile $PROFILE stepfunctions start-execution --state-machine-arn $STATE_MACHINE_ARN --input '{"Suffix":"!"}' | jq -r '.executionArn')
aws --profile $PROFILE stepfunctions describe-execution --execution-arn $EXECUTION_ARN | jq -r '.status'
```

When `SUCCEEDED`:

Read the file `result.txt` from the third Bucket.

```
aws --profile $PROFILE s3 cp s3://$THIRD_BUCKET/result.txt - | head
```
