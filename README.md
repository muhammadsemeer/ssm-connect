## Install SSM Connect

1. Linux

    ```bash
    curl -fsSL https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/refs/heads/master/install.sh | sudo bash
    ```

   or using wget

    ```bash
    wget -qO- https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/refs/heads/master/install.sh | sudo bash
    ```

2. Mac

    ```bash
    curl -fsSL https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/refs/heads/master/install.sh | bash
    ```

   or using wget

    ```bash
    wget -qO- https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/refs/heads/master/install.sh | bash
    ```


Verify

```bash
ssm-connect --help
```

## Setup

Create a alias

```bash
ssm-connect -a <name> <instance-id>
```

Connect

```bash
#connect interactively

ssm-connect

# connect a specific instance directly

ssm-connect <alias-name>

#for first time it will ask you setup aws cli 
ssm-connect
[INFO] AWS profile 'ssm-session-manager' not found. Configuring...
AWS Access Key ID [None]: <your-key-id>
AWS Secret Access Key [None]: <your-access-key>
Default region name [None]: ap-south-1
Default output format [None]: json
```

> ⚠️ Make sure you have the necessary IAM permissions to use SSM and Session Manager. You can refer to the [AWS documentation](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started.html) for more details.

> ⚠️ Do not use access keys with `administrator` access, as it poses potential security risks.

For more command

```bash
ssm-connect --help
```