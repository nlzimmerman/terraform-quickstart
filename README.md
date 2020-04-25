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
