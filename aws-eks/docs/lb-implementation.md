

# before we start some basics 

A ServiceAccount is the identity Kubernetes assigns to workloads running inside pods. It allows applications to authenticate to the Kubernetes API securely using a mounted token. The ServiceAccount itself only provides identity; RBAC determines what that identity can do through Roles and RoleBindings.

For example, if I deploy Prometheus, it needs to discover pods and services to scrape metrics. I create a prometheus-sa ServiceAccount, bind it to a Role that allows get, list, and watch on pods and services, and assign that ServiceAccount to the Prometheus pod. When Prometheus calls the Kubernetes API, it automatically uses the mounted ServiceAccount token. The API server verifies the token, checks the RoleBinding, and only allows those read operations. This follows the principle of least privilege, so the application gets only the permissions it actually needs.


---
# detail implementation of lb 

module "lb_controller_irsa" 
    will create an AWS IAM Role for the AWS Load Balancer Controller and attach the required Load Balancer Controller IAM policy to that role. This policy gives the controller permission to create, modify, and delete AWS load-balancer-related resources such as load balancers, target groups, listeners, and security groups.

    In the oidc_providers configuration, we specify the OpenID Connect provider of our EKS cluster and the Kubernetes ServiceAccount that is allowed to use this IAM Role. In our case, it's the aws-load-balancer-controller ServiceAccount in the kube-system namespace.

helm_release block 
    installs the AWS Load Balancer Controller into our EKS cluster.

    serviceAccount.name tells the Helm chart which ServiceAccount the Load Balancer Controller should use.

    serviceAccount.annotations.eks.amazonaws.com/role-arn connects that Kubernetes ServiceAccount to the IAM Role we created earlier. This allows the Load Balancer Controller Pod to obtain the AWS permissions associated with that IAM Role.

    So the overall flow is:

    Controller Pod → ServiceAccount → IAM Role → AWS permissions → Create/manage Load Balancers.

simple mental model 

- helm - creates the lb controller pod and attaching it to a specific service account 
- isra - so we have lb controller permission role - that we are assigning to lb controller service account 