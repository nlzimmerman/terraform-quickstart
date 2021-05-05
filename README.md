# Getting started deploying AWS infrastructure with Terraform

Thinking about hardware is cool, but not thinking about hardware so you can focus on solving your real problem is a lot cooler.

AWS is a good way to stop thinking about hardware so you can solve your real problem, but actually stringing AWS together is a pain: the UI is a struggle, and there's a lot of things you have to do to do anything at all.

Terraform is the best way I've heard of to provision AWS, but comprehensive tutorials are awfully rare. This is an attempt to present a comprehensive tutorial, following an example that mirrors a problem I wanted to solve, showing what I had to do to get started. The basic problem architecture is:

1. I have a network that I trust.
2. In that network, I have an EC2 instance that I trust running some bash scripts that I trust. I'm not allowed to rewrite the bash scripts in python, or install `awscli` on the machines.
3. Those bash scripts need to make some _stuff_ happen: query a database, do something that can't be expressed in SQL, and write the results to a different database.
4. For administrative reasons, doing that _stuff_ on the machine that the bash scripts live on is a non-starter. I could stand up another machine, but then I'd have two EC2 instances to worry about.
5. So, let's use managed cloud services to get that _stuff_ done.

Here's the disclaimer: I'm comfortable with the security of what I've done here, but this is a REST API that could real work happen using real secret credentials, and all you need to do to make it go is have access to the right subnet. Consult your security expert before you duplicate this. If your place of employement doesn't have a security expert, that could make _you_ the security expert; don't get fired.

Here's what I want to do; this will evolve over time:
1. Create a private network: a VPC, a private instance that doesn't have a public IP address, a bastion host that does, a router so the private stuff can still get to the real internet, and public and private subnets for each.
2. Write a Lambda function that can retrieve a secret from AWS secrets manager, use it to query a database, do something useful, and write out to the same database. Right now, the database is fake but the secret is real: you're here because you want to figure out how to get Terraform working, not SQLAlchemy.
3. Run that function asynchronously, receiving instructions from an SQS queue. This function would write out to a database too, but we'll just have it write out to the logger.
4. Make the function able to write to CloudWatch logs we we have some idea of what's going on.

# Getting started

Before you can do anything here, you need to

1. Get a copy of [Terraform](https://www.terraform.io/downloads.html).
2. Set up your AWS credentials. I'm using my account's root credentials, because  I'm doing this for fun. You wouldn't want to use those on an account where anything important happened. AWS documentation isn't as straightforward as one might like, but [you want to read up](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html#create-iam-users) before you do anything important. I set my AWS credentials in environment variables (`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`).

# About Terraform

TODO: write more here. TL;DR: Terraform works by declaring resources that you can think of as instances of classes that take arguments upon instantiation and, if they can be successfully created, have attributes that are computed and can be used as inputs to other objects. Terraform computes the entire state at once: the order in which you declare resources never matters, and terraform will tell you if you declare an infeasible state.

# Step zero: make a network and convince yourself it works

## Networking

AWS networking is a bit confusing. At a high level

1. A VPC is a private network that exists in one [region](https://aws.amazon.com/about-aws/global-infrastructure/regions_az/)
2. VPCs contain one or more subnets, each of which exist in a single availability zone. Routing between subnets inside a single VPC doesn't require any special work. Subnets can be public or private: resources on public subnets get routable public IPs.
3. Resources on public subnets neerd to route their outbound traffic through an internet gateway. VPCs can only have one internet gateway each.
4. Resources on private subnets don't have a route to the real internet unless you stand up a router (called a NAT gateway) in a public subnet. This may or may not be what you want to do — in my case, I need a router because the database I'd be interested in querying if this example represented real work would be outside of the VPC in question. Or I could have just used a public subnet. The decision to use a private subnet is, fundamentally, a security question. I haven't spent a lot of time investigating the relative costs of maintaining NAT gateways.
5. All subnets need to be associated with precisely one route table, though a given route table can be associated with more than one subnet. Local VPC routing is handled automatically, but if you want traffic to flow to the real internet, you have to explain how it needs to get there.
  - Public subnets can route outbound traffic directly to the internet gateway.
  - Private subnets need to route outbound traffic to a NAT gateway, which ought to be in the same AZ. These NAT gateways themselves sit in public subnets so can pass traffic out to the real internet.
  - Define route tables by defining the route table, adding rules to it, and then associate it with one or more subnets. Route tables are global across VPCs so it's perfectly possible to, e.g. route to a NAT gateway in a different AZ. Take care not to do that, unless you know why you want to.
6. You also need security groups: all inbound traffic is blocked by default, and while outbound traffic is permitted, [terraform will remove that egress rule when it makes security groups](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group).

I've declared the VPC, the subnets, the routing tables, and a very simple security group in the file `network.tf`.

I've done something here that might be over-clever: you can specify the number of availability zones you want to use, as a number, _or_ you can specify the list of availability zones you want to use. If you specify neither, you get one availability zone. If you specify both, the list you specify takes precedence.

Note: The `network_info` and `ordered_availability_zones` outputs are just for debugging — maybe it would be a real output if `network.tf` were a module, but I made it just so I could click through the AWS console and convince myself everything was set up right. Superflous outputs are clutter, so I don't imagine I'd do this in a real project.

## Virtual Machines

You may or may not actually want VMs in your network — we're deploying Lambda functions here, after all, but it's a good, convenient way to test that everything is working.

I've declared a few small Ubuntu VMs, one in each subnet. We have two subnets per availability zone so that means at least two VMs. You sould be able to login to the public VMs from anywhere in the world using the SSH public key you specified.

```bash
ssh -A -i mykey.pem ubuntu@3.137.185.193
```
Once you've logged into a machine on a public subnet, you should be able to access any of the machines, public or private, by SSHing into their private IP.

```bash
# we aren't forwrding the agent here and we're already logged in as ubuntu
ssh 10.250.23.69
```

Internet access should work on machines with and without public IP addresses, e.g.

```bash
sudo apt update
```

A few notes:
1. You need to specify your SSH key as a variable. Since SSH keys are long, you'll want to create a [`.tfvars` file](https://www.terraform.io/docs/language/values/variables.html), e.g.
```
ec2_ssh_key = "ssh-rsa [a lot of hex]"
```
2. The SSH key name is set using a [random pet](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/pet) to avoid name collision. SSH keypairs have names that are normally human-specified that you use as the ID, so if the name were already in use you'd have an error.
3. The `ec2_ip_addresses` output contains two IP addresses for public machines; the first is public, the second is private. Private machines only have a single IP address. This is intended to be human-readable but I didn't put much thought into.

**You can check out just the networking and the ec2 instances by checking out the `networking` branch and running `terraform apply`.**

# Step 1: Making a secret and getting access to it from EC2.

Our secret is stored in [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/), which encrypts strings and hands them out only to authenticated services.

This secret represents a username and password for a notional database — ideally, you'd want to rotate these passwords, which Secrets Manager supports. (TODO: figure out how to do that, update this to reflect that.) In this example, it's a hardcoded service account, which is still better than setting your credentials in environment variables and a *lot* better than putting your password into your source code.

Secrets consist of the secret itself, and a secret version (which would change if we rotated them). Those are declared at the top of `secrets.tf`, until about line 30.

If you just made the secret, you could retrieve it from the console using your root credentials, but that wouldn't be much of a secret. In order to make it useful, we want to give your other AWS resources permission to retrieve it themselves. To do this, we need to use IAM roles.

I struggled a bit to figure out IAM roles at first, possibly because I'm an impatient reader. [This is the best page I've found.](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_passrole.html)

In Terraform parlance:

1. You need an `aws_iam_role` (a _trust policy_, on the page I just linked) that will say "this is a role that can be assumed by resources that have been associated with it." Common practice is to scope a `aws_iam_role` to just one type of resource, e.g. `ec2.amazonaws.com`.
2. What roles are allowed to do are set in a `aws_iam_policy` (a _permissions policy_, ibid.), which consists of a policy document. The mapping between `aws_iam_role` and `aws_iam_policy` is *many-to-many*: you attach a policy to a role using a `aws_iam_role_policy_attachment`.
3. For EC2 instances, you assign roles to instances by first creating a [`aws_iam_instance_profile`](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html), assigning the role to that, and then assigning the instance profile to the instance.

Around the internet, you'll see lots of ways to generate policy documents, including manually specifying the JSON
```
assume_role_policy = <<EOF
{
"Version": "2012-10-17",
"Statement": [
  {
    "Effect": "Allow",
    "Principal": {
      "Service": "ec2.amazonaws.com"
    },
    "Action": "sts:AssumeRole"
  }
]
}
EOF
```

or using jsonencode
```
assume_role_policy = jsonencode({
    "Version" = "2012-10-17",
    "Statement" = [
      {
        "Effect" = "Allow",
        "Principal" = {
          "Service" = "ec2.amazonaws.com"
        },
        "Action" = "sts:AssumeRole"
      }
    ]
  })

```

I eschew both of those approaches in favor of using [`data.aws_iam_policy_document`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) which includes somewhat better validation. Note that these objects are terraform-specific, and not part of AWS: they still amount to just strings once they're produced

## How IAM roles fit together for EC2

1. The `aws_iam_role` has a _name_ and a _assume_role_policy_, which is just a policy document, as a string. The _assume_role_policy_ tells you who can assume this role.
2. The `aws_iam_policy` has a _name_ and a _policy_, which is also just a string. The _policy_ says what roles with this policy attached to them can do. Note that in this example, what we're doing is giving permission to access the secret, identified by its id.
3. The `aws_iam_role_policy_attachment` maps roles to policies by their _ids_.
4. The `aws_iam_instance_profile` objects has a _name_ and references a _role_ by its id.
5. You attach an `aws_iam_instance_profile` to an `aws_instance` by its _name_.

In this example, I've given just the VMs in the private subnets the ability to access the secrets — I just did this to show that some machines can access the secret and some can't.

**You can the secrets-rlated changes by checking out the `secrets` branch and running `terraform apply`.**

Check the outputs of this application and make a note of the public IP address of one of your public addresses and a (private) IP address of one of your private instances.

My output is
```
ec2_ip_addresses = {
  "private" = {
    "us-east-2a" = "10.250.91.98"
    "us-east-2b" = "10.250.55.118"
    "us-east-2c" = "10.250.23.69"
  }
  "public" = {
    "us-east-2a" = [
      "3.137.185.193",
      "10.250.217.17",
    ]
    "us-east-2b" = [
      "13.58.94.168",
      "10.250.177.234",
    ]
    "us-east-2c" = [
      "18.188.98.240",
      "10.250.157.117",
    ]
  }
}
```

so, assuming I have my SSH key set up, I can first log into a public instance and see if I can access my secret.
```
$ ssh -A ubuntu@3.137.185.193

$ aws secretsmanager get-secret-value --region us-east-2 --secret-id example_secret
Unable to locate credentials. You can configure credentials by running "aws configure".
```

I can't. If I then go to one of the machines that has been granted access to the secret via IAM:

```
# run this from your public instance
$ ssh 10.250.91.98

$ aws secretsmanager get-secret-value --region us-east-2 --secret-id example_secret
{
    "ARN": "arn:aws:secretsmanager:us-east-2:762806054286:secret:example_secret-hVHVEQ",
    "Name": "example_secret",
    "VersionId": "28DDAE39-3ADF-43BD-8BD7-07F7FF64EAF3",
    "SecretString": "{\"username\": \"user\", \"password\": \"password\"}",
    "VersionStages": [
        "AWSCURRENT"
    ],
    "CreatedDate": 1619483796.846
}
```

There we are!
