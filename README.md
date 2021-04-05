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

# Networking

AWS networking is a bit confusing. At a high level

1. A VPC is a private network that exists in one [region](https://aws.amazon.com/about-aws/global-infrastructure/regions_az/)
2. VPCs contain one or more subnets, each of which exist in a single availability zone. Routing between subnets inside a single VPC doesn't require any special work. Subnets can be public or private: resources on public subnets get routable public IPs.
3. Resources on private subnets don't have a route to the real internet unless you stand up a router in a public subnet. This may or may not be what you want to do — in my case, I need a router because the database I'd be interested in querying if this example represented real work would be outside of the VPC in question.

I've declared the VPC in the file `network.tf`.
