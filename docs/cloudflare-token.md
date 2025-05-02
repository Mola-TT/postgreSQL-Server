# Cloudflare API Token Management

This document explains how to securely manage your Cloudflare API tokens for Let's Encrypt DNS validation.

## Security Considerations

For security reasons, we do not store the Cloudflare API token directly in the environment files that might be committed to version control. Instead, we use a separate, secure file that is excluded from Git.

## Setting Up Your Cloudflare API Token

1. Create a new API token at https://dash.cloudflare.com/profile/api-tokens

2. Use the "Edit zone DNS" template or manually add these permissions:
   - Zone.Zone: Read
   - Zone.DNS: Edit

3. Restrict the token to only the specific zone (domain) you are using

4. Add your token to a secure location on the server:

   ```bash
   sudo mkdir -p /etc/letsencrypt/cloudflare
   sudo bash -c 'echo "export CLOUDFLARE_API_TOKEN=your-token-here" > /etc/letsencrypt/cloudflare/token.env'
   sudo chmod 600 /etc/letsencrypt/cloudflare/token.env
   ```

5. Make sure `USE_CLOUDFLARE_DNS=true` is set in your environment configuration

## Troubleshooting

If you see errors like "API token is invalid or doesn't have required permissions":

1. Verify your token has the correct permissions
2. Check that the domain is managed by the Cloudflare account associated with the token
3. Consider generating a new token if the current one has expired or been revoked

## Testing with Let's Encrypt Staging

By default, the system uses Let's Encrypt's staging environment when `PRODUCTION=false`. This has higher rate limits and doesn't count against production rate limits.

To switch to the production environment for real certificates:

```bash
# Edit your user.env file
PRODUCTION=true
```

Remember that Let's Encrypt production has rate limits that could affect your ability to issue certificates if too many requests are made. 