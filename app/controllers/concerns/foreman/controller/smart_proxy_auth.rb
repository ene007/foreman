require 'resolv'
require 'uri'

module Foreman::Controller::SmartProxyAuth
  extend ActiveSupport::Concern

  module ClassMethods
    def add_puppetmaster_filters(actions)
      skip_before_filter :require_login, :only => actions
      skip_before_filter :require_ssl, :only => actions
      skip_before_filter :authorize, :only => actions
      skip_before_filter :verify_authenticity_token, :only => actions
      skip_before_filter :set_taxonomy, :only => actions
      skip_before_filter :session_expiry, :update_activity_time, :only => actions
      before_filter :require_puppetmaster_or_login, :only => actions
      attr_reader :detected_proxy
    end
  end

  # Permits registered puppetmasters or a user with permission
  def require_puppetmaster_or_login
    if !Setting[:restrict_registered_puppetmasters] or auth_smart_proxy(SmartProxy.with_features("Puppet", "Chef Proxy"), Setting[:require_ssl_puppetmasters])
      set_admin_user
      return true
    end

    require_login
    unless User.current
      render_error 'access_denied', :status => :forbidden unless performed? and api_request?
      return false
    end
    authorize
  end

  # Filter requests to only permit from hosts with a registered smart proxy
  # Uses rDNS of the request to match proxy hostnames
  def auth_smart_proxy(proxies = SmartProxy.all, require_cert = true)
    request_hosts = nil
    if request.ssl?
      dn = request.env[Setting[:ssl_client_dn_env]]
      if dn && dn =~ /CN=(\S+)/i
        verify = request.env[Setting[:ssl_client_verify_env]]
        if verify == 'SUCCESS'
          request_hosts = [$1]
        else
          logger.warn "SSL cert has not been verified (#{verify}) - request from #{request.ip}, #{dn}"
        end
      elsif require_cert
        logger.warn "No SSL cert with CN supplied - request from #{request.ip}, #{dn}"
      else
        request_hosts = Resolv.new.getnames(request.ip)
      end
    elsif SETTINGS[:require_ssl]
      logger.warn "SSL is required - request from #{request.ip}"
    else
      request_hosts = Resolv.new.getnames(request.ip)
    end
    return false unless request_hosts

    hosts = Hash[proxies.map { |p| [URI.parse(p.url).host, p] }]
    allowed_hosts = hosts.keys.push(*Setting[:trusted_puppetmaster_hosts])
    logger.debug { ("Verifying request from #{request_hosts} against #{allowed_hosts.inspect}") }
    unless host = allowed_hosts.detect { |p| request_hosts.include? p }
      logger.warn "No smart proxy server found on #{request_hosts.inspect} and is not in trusted_puppetmaster_hosts"
      return false
    end
    @detected_proxy = hosts[host] if host
    true
  end
end
