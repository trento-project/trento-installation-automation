# Generate ephemeral SSH key pair for VM access
resource "tls_private_key" "vm_ssh" {
  algorithm = "ED25519"
}

# Save private key to local file
resource "local_file" "private_key" {
  content         = tls_private_key.vm_ssh.private_key_openssh
  filename        = "${path.module}/../.ssh-key-temp"
  file_permission = "0600"
}

# Output the private key path for scripts to use
output "ssh_private_key_path" {
  value       = local_file.private_key.filename
  description = "Path to the generated SSH private key"
}

output "ssh_public_key" {
  value       = tls_private_key.vm_ssh.public_key_openssh
  description = "Generated SSH public key"
}
