#!/bin/bash
# Installer for GitLab on RHEL 6 (Red Hat Enterprise Linux and CentOS)
# mattias.ohlsson@inprose.com
#
# Submit issues here: github.com/mattias-ohlsson/gitlab-installer

# Define the public hostname
export GL_HOSTNAME=$HOSTNAME

# Define gitlab installation root
export GL_INSTALL_ROOT=/var/www/gitlabhq

# Define the version of ruby the environment that we are installing for
export RUBY_VERSION=ruby-1.9.2-p290

# Define the rails environment that we are installing for
export RAILS_ENV=production

die()
{
  # $1 - the exit code
  # $2 $... - the message string

  retcode=$1
  shift
  printf >&2 "%s\n" "$@"
  exit $retcode
}


echo "### Check OS (we check if the kernel release contains el6)"
uname -r | grep "el6" || die 1 "Not RHEL or CentOS"


echo "### Check if we are root"
[[ $EUID -eq 0 ]] || die 1 "This script must be run as root"


echo "### Installing packages"

# Install epel-release
rpm -Uvh http://download.fedoraproject.org/pub/epel/6/i386/epel-release-6-5.noarch.rpm

# Modified list from gitlabhq
yum install -y \
make \
libtool \
openssh-clients \
gcc \
libxml2 \
libxml2-devel \
libxslt \
libxslt-devel \
python-devel \
wget \
readline-devel \
ncurses-devel \
gdbm-devel \
glibc-devel \
tcl-devel \
openssl-devel \
db4-devel \
byacc \
httpd \
gcc-c++ \
curl-devel \
openssl-devel \
zlib-devel \
httpd-devel \
apr-devel \
apr-util-devel \
sqlite-devel \
libicu-devel \
gitolite \
redis \
sudo \
mysql-devel


echo "### Install and start postfix"

# Install postfix
yum install -y postfix

# Start postfix
service postfix start


echo "### Create the git user and keys"

# Create the git user 
/usr/sbin/adduser -r -m --shell /bin/bash --comment 'git version control' git

# Create keys as the git user
su - git -c 'ssh-keygen -q -N "" -t rsa -f ~/.ssh/id_rsa'


echo "### Set up Gitolite"

# Run the installer as the git user
su - git -c "gl-setup -q /home/git/.ssh/id_rsa.pub"

# Change the umask (see whe gitlab wiki)
sed -i 's/0077/0007/g' /home/git/.gitolite.rc

# Change permissions on repositories and home (group access)
chmod 750 /home/git
chmod 770 /home/git/repositories


echo "### Set up Gitolite access for Apache"
# Shoplifted from github.com/gitlabhq/gitlabhq_install

# Create the ssh folder
mkdir /var/www/.ssh

# Use ssh-keyscan to skip host verification problem
ssh-keyscan localhost > /var/www/.ssh/known_hosts

# Copy keys from the git user 
cp /home/git/.ssh/id_rsa* /var/www/.ssh/

# Apache will take ownership
chown apache:apache -R /var/www/.ssh

# Add the git group to apache
usermod -G git apache


echo "### Installing RVM and Ruby"

# Instructions from https://rvm.io
curl -L get.rvm.io | bash -s stable 

# Load RVM
source /etc/profile.d/rvm.sh

# Install Ruby
rvm install $RUBY_VERSION

# Install core gems
gem install rails passenger rake bundler grit --no-rdoc --no-ri


echo "### Install pip and pygments"

yum install -y python-pip
pip-python install pygments


echo "### Install GitLab"

# Download code
cd /var/www && git clone https://github.com/gitlabhq/gitlabhq.git

# Install GitLab
cd $GL_INSTALL_ROOT && bundle install


echo "### Install Passenger Apache module"

# Run the installer
rvm all do passenger-install-apache2-module -a


echo "### Start and configure redis"

# Start redis
/etc/init.d/redis start

# Automatically start redis
chkconfig redis on


echo "### Configure GitLab"

# Go to install root
cd $GL_INSTALL_ROOT

# Use SQLite
cp config/database.yml.sqlite config/database.yml

# Rename config files
cp config/gitlab.yml.example config/gitlab.yml

# Change gitlabhq hostname to GL_HOSTNAME
sed -i "s/host: localhost/host: $GL_HOSTNAME/g" config/gitlab.yml

# Change the from email address
sed -i "s/from: notify@gitlabhq.com/from: notify@$GL_HOSTNAME/g" config/gitlab.yml

# Use localhost to relay mail
sed -i "s/host: gitlabhq.com/host: localhost/g" config/gitlab.yml

# Setup DB
rvm all do rake db:setup RAILS_ENV=production
rvm all do rake db:seed_fu RAILS_ENV=production


echo "### Configure Apache"

# Get the passenger version
export PASSENGER_VERSION=`find /usr/local/rvm/gems/$RUBY_VERSION/gems -type d -name "passenger*" | cut -d '-' -f 4`

# Create a config file for gitlab
cat > /etc/httpd/conf.d/gitlabhq.conf << EOF
<VirtualHost *:80>
    ServerName $GL_HOSTNAME
    DocumentRoot $GL_INSTALL_ROOT/public
    LoadModule passenger_module /usr/local/rvm/gems/$RUBY_VERSION/gems/passenger-$PASSENGER_VERSION/ext/apache2/mod_passenger.so
    PassengerRoot /usr/local/rvm/gems/$RUBY_VERSION/gems/passenger-$PASSENGER_VERSION
    PassengerRuby /usr/local/rvm/wrappers/$RUBY_VERSION/ruby
    <Directory $GL_INSTALL_ROOT/public>
        AllowOverride all
        Options -MultiViews
    </Directory>
</VirtualHost>
EOF

# Enable virtual hosts in httpd
cat > /etc/httpd/conf.d/enable-virtual-hosts.conf << EOF
NameVirtualHost *:80
EOF


# Ensure that apache owns all of gitlabhq - No shallower
chown -R apache:apache $GL_INSTALL_ROOT

# permit apache the ability to write gem files if needed..  To be reviewed.
chown apache:root -R /usr/local/rvm/gems/


echo "### Configure SELinux"

# Disable SELinux 
sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config

# Turn off SELinux in this session
setenforce 0


echo "### Configure iptables"

# Open port 80
iptables -I INPUT -p tcp -m tcp --dport 80 -j ACCEPT

# Save iptables
service iptables save


echo "### Start Apache"

# Start on boot
chkconfig httpd on

# Start Apache
service httpd start