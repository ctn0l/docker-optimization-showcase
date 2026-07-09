package com.example.docker_optimization_showcase.service;

import org.springframework.stereotype.Service;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.lang.management.ManagementFactory;
import java.lang.management.RuntimeMXBean;

/**
 * Service that collects system and application information.
 * Returns an AppInfo DTO with: app name, version, JVM version, hostname, uptime.
 */
@Service
public class InfoService {

    /**
     * Immutable DTO for the JSON response.
     * Fields: app, version, javaVersion, hostname, uptimeSeconds.
     */
    public record AppInfo(String app,
                          String version,
                          String javaVersion,
                          String hostname,
                          long uptimeSeconds) {}

    /**
     * Collects all information and returns a populated AppInfo.
     * Handles exceptions (e.g., UnknownHostException) with fallback values ("unknown").
     */
    public AppInfo getInfo() {
        // Read system properties
        String appName = System.getProperty("application.name", "docker-optimization-showcase");
        String appVersion = System.getProperty("application.version", "0.1.0");

        // JVM version
        String javaVersion = System.getProperty("java.version", "unknown");

        // Hostname (handles exceptions)
        String hostname = getHostname();

        // Uptime from RuntimeMXBean (converted from milliseconds to seconds)
        RuntimeMXBean runtimeMxBean = ManagementFactory.getRuntimeMXBean();
        long uptimeSeconds = runtimeMxBean.getUptime() / 1000;

        return new AppInfo(appName, appVersion, javaVersion, hostname, uptimeSeconds);
    }

    /**
     * Retrieves the hostname of the container.
     * Fallback to "unknown" if it fails (e.g., DNS not reachable).
     */
    private String getHostname() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            // Safe fallback for minimal Docker environments without configured hostname
            return "unknown";
        }
    }
}
