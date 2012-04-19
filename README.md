![BVox](http://bvox.net/images/logo-bvox-big.png)

#Boxgrinder XenServer Platform Plugin

Build XenServer/XCP compatible images with Boxgrinder.

#Requirements

* Boxgrinder (http://boxgrinder.org)

Previous Boxgrinder knowledge assumed.

#Installation

    gem install boxgrinder-xenserver-platform-plugin

#Usage

Building Ubuntu appliances:

    boxgrinder-build -lboxgrinder-ubuntu-plugin,xenserver-platform-plugin -p xenserver oneiric.appl

Building Fedora/CentOS appliances:

    boxgrinder-build -lxenserver-platform-plugin -p xenserver fedora.appl

Note that to build Ubuntu appliances, you need to run Boxgrinder in Ubuntu. Building Ubuntu appliances from Fedora won't work. Building Fedora appliances from Ubuntu won't work either.

Get some tested appliance definitions for XenServer from https://github.com/bvox/boxgrinder-appliances/tree/master/bvox

#Building the plugin

    rake build

# Copyright

Copyright (c) 2012 BVox S.L. See LICENSE.txt for
further details.

