# Troubleshooting Mac Runner

## Container Isolation Issues

### Container isolation not available

**Symptoms:**
- Container isolation option grayed out in GUI
- Error: "Container isolation requires macOS 26+"
- Automatically falls back to user isolation

**Causes:**
1. macOS version < 26
2. Not running on Apple Silicon
3. Containerization framework not available

**Solutions:**
1. **Check macOS version:**
   ```bash
   sw_vers -productVersion
   ```
   Container isolation requires macOS 26.0 or later.

2. **Check CPU architecture:**
   ```bash
   uname -m
   ```
   Should return `arm64`. Intel Macs (`x86_64`) do not support container isolation.

3. **Verify Containerization framework:**
   - Ensure Xcode 26+ is installed
   - Container isolation uses Apple's Containerization framework, which is only available on Apple Silicon with macOS 26+

4. **Workaround:**
   - Use **user isolation** instead for macOS-based workflows
   - User isolation provides strong security on macOS 15+

### Linux kernel not found

**Symptoms:**
- Error: "Linux kernel not found at path: /path/to/vmlinux"
- Container creation fails

**Causes:**
- Linux kernel binary not downloaded or corrupted

**Solutions:**
1. **Download the kernel manually:**
   ```bash
   # Create Mac Runner app support directory
   mkdir -p ~/Library/Application\ Support/MacRunner

   # Download Linux kernel (placeholder - actual URL TBD)
   # The kernel will be bundled with Mac Runner in future releases
   ```

2. **Check kernel permissions:**
   ```bash
   ls -la ~/Library/Application\ Support/MacRunner/vmlinux
   ```
   Should be readable by your user.

3. **Report the issue:**
   This is likely a bug. Please file an issue at https://github.com/omniaura/mac-runner/issues

### Container fails to start

**Symptoms:**
- Runner status shows "Error"
- Logs show container start failure

**Causes:**
1. Network configuration issues
2. Insufficient resources (CPU/memory)
3. OCI image pull failure

**Solutions:**
1. **Check available resources:**
   ```bash
   # Ensure at least 2 CPU cores and 2 GiB RAM available
   sysctl -n hw.ncpu
   sysctl -n hw.memsize
   ```

2. **Check network connectivity:**
   ```bash
   # Verify you can reach GitHub's container registry
   ping ghcr.io
   ```

3. **Check Docker Hub connectivity (if using docker.io images):**
   ```bash
   ping hub.docker.com
   ```

4. **Inspect container logs:**
   Container logs are stored in:
   ```
   ~/Library/Application Support/MacRunner/logs/
   ```

5. **Try a different base image:**
   Edit runner configuration to use a smaller base image like `ubuntu:22.04` instead of `ghcr.io/actions/runner:latest`

### Container networking issues

**Symptoms:**
- Runner can't connect to GitHub
- Workflows fail with network timeouts

**Causes:**
- vmnet network configuration issues
- Firewall blocking container traffic

**Solutions:**
1. **Check vmnet status:**
   ```bash
   # List network interfaces
   ifconfig | grep vmnet
   ```

2. **Check firewall settings:**
   - System Settings → Network → Firewall
   - Ensure Mac Runner is allowed

3. **Restart networking:**
   ```bash
   # Restart Mac Runner app
   # Containers will be recreated with fresh network config
   ```

## User Isolation Issues

### "User _macrunner does not exist"

**Symptoms:**
- Runner fails to start with user isolation enabled
- Error: "User _macrunner does not exist"

**Causes:**
- Dedicated user not created yet
- User creation failed

**Solutions:**
1. **Create user manually:**
   ```bash
   sudo dscl . -create /Users/_macrunner
   sudo dscl . -create /Users/_macrunner UserShell /usr/bin/false
   sudo dscl . -create /Users/_macrunner RealName "Mac Runner"
   sudo dscl . -create /Users/_macrunner UniqueID 540
   sudo dscl . -create /Users/_macrunner PrimaryGroupID 20
   sudo dscl . -create /Users/_macrunner NFSHomeDirectory /var/empty
   ```

2. **Grant necessary permissions:**
   ```bash
   # Allow the dedicated user to run GitHub Actions runner
   sudo dseditgroup -o edit -a _macrunner -t user admin
   ```

3. **Verify user exists:**
   ```bash
   dscl . -read /Users/_macrunner
   ```

### Permission denied errors

**Symptoms:**
- Runner fails with "Permission denied"
- Can't write to workspace

**Causes:**
- Dedicated user doesn't have access to runner workspace
- File ownership issues

**Solutions:**
1. **Check workspace permissions:**
   ```bash
   ls -la ~/Library/Application\ Support/MacRunner/runners/
   ```

2. **Fix ownership:**
   ```bash
   sudo chown -R _macrunner:staff ~/Library/Application\ Support/MacRunner/runners/<runner-id>
   ```

3. **Grant workspace access:**
   ```bash
   chmod 755 ~/Library/Application\ Support/MacRunner/runners/<runner-id>
   ```

## General Issues

### Runner stuck in "busy" state

**Symptoms:**
- Runner shows as busy but no job is running
- Can't start new jobs

**Causes:**
- Runner process crashed mid-job
- PID file stale

**Solutions:**
1. **Restart the runner:**
   ```bash
   mac-runner stop <runner-name>
   mac-runner start <runner-name>
   ```

2. **Check for zombie processes:**
   ```bash
   ps aux | grep Runner.Listener
   ```

3. **Clean up stale PID files:**
   ```bash
   rm ~/Library/Application\ Support/MacRunner/runners/<runner-id>/*.pid
   ```

### "gh CLI not found"

**Symptoms:**
- Can't add runners
- Error: "gh command not found"

**Causes:**
- GitHub CLI not installed
- PATH not configured

**Solutions:**
1. **Install gh CLI:**
   ```bash
   brew install gh
   ```

2. **Authenticate:**
   ```bash
   gh auth login
   ```

3. **Verify installation:**
   ```bash
   which gh
   gh --version
   ```

### "Not authenticated with GitHub"

**Symptoms:**
- Can't fetch repos
- Can't create registration tokens

**Causes:**
- GitHub CLI not authenticated
- Token expired

**Solutions:**
1. **Re-authenticate:**
   ```bash
   gh auth login
   ```

2. **Check auth status:**
   ```bash
   gh auth status
   ```

3. **Test API access:**
   ```bash
   gh api user
   ```

### Runner not showing up on GitHub

**Symptoms:**
- Runner shows as "running" in Mac Runner
- Not visible in GitHub repo settings

**Causes:**
- Registration token expired
- Runner offline before first job

**Solutions:**
1. **Check runner status on GitHub:**
   ```bash
   gh api repos/owner/repo/actions/runners
   ```

2. **Re-register runner:**
   ```bash
   mac-runner remove <runner-name>
   mac-runner add owner/repo --name <runner-name>
   ```

3. **Verify runner logs:**
   ```bash
   cat ~/Library/Application\ Support/MacRunner/runners/<runner-id>/_diag/*.log
   ```

## Performance Issues

### Slow container startup

**Symptoms:**
- Containers take > 5 seconds to start
- Jobs queued waiting for runner

**Causes:**
- Large container images
- Slow network (pulling images)
- Resource contention

**Solutions:**
1. **Use smaller base images:**
   - Try `ubuntu:22.04` instead of full runner images
   - Pre-build custom images with dependencies

2. **Pre-pull images:**
   ```bash
   # Manually pull images to cache them
   # (Exact command TBD - depends on container CLI tool)
   ```

3. **Increase resource allocation:**
   - Close resource-intensive applications
   - Ensure adequate free memory (4+ GiB recommended)

### High CPU usage

**Symptoms:**
- Mac fan constantly running
- High CPU usage in Activity Monitor

**Causes:**
- Multiple concurrent jobs
- Resource-intensive builds

**Solutions:**
1. **Limit concurrent runners:**
   - Stop unused runners
   - Reduce number of active runners

2. **Use Pause feature:**
   - Pause all runners when not needed
   - Menu bar → Pause All Runners

3. **Configure quiet hours:**
   ```bash
   # Pause runners during specific hours
   # (GUI: Settings → Quiet Hours)
   ```

## Getting Help

If you're still experiencing issues:

1. **Check existing issues:** https://github.com/omniaura/mac-runner/issues
2. **File a new issue:** Include:
   - macOS version (`sw_vers`)
   - Mac Runner version
   - Isolation mode in use
   - Full error message
   - Steps to reproduce
3. **Enable debug logging:**
   ```bash
   # Future feature - debug flag
   mac-runner --debug
   ```

## Common Error Messages

### "Container isolation service not initialized"
- **Cause:** Container service failed to initialize
- **Solution:** Check logs, verify macOS 26+ and Apple Silicon

### "Failed to create container: OCI runtime error"
- **Cause:** Container runtime failure
- **Solution:** Check network, verify image reference, restart Mac Runner

### "User isolation requires macOS 15+"
- **Cause:** macOS version too old for user isolation
- **Solution:** Upgrade to macOS 15+ or use no isolation mode

### "Registration token expired"
- **Cause:** GitHub registration token (valid for 1 hour) expired
- **Solution:** Remove and re-add the runner to get a fresh token
