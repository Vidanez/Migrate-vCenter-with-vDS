#MIGRATE A CLUSTER FROM ONE VCENTER TO ANOTHER VCENTER
This script is design to migrate a complete cluster from one vcenter to another vcenter complete different without service disruption.

Features:

	Migrates VM folder locations and permissions

	Migrates HA/DRS rules

	Migrates Custom Attributes

	Migrates VDS and port groups

	Process Clusters in serial order

	Use a CSV files like this example:

		SourceVC,destinationVC,Sourcecluster,SourceDC,DestinationDC

pepevcenter1,antoniovcenter2,pepecluster,datacenter1,datacenter2

	
During the process it does questions in order to allow manual intervention about:


	If in the first cluster you already migrate the folders order in the datacenter you don’t need to do it again

	If you already create the vDS on any of the cluster you can skip it

	You have to manually decide which interface are you going to use in the vSS created to migrate the vDS in order to don’t lose connectivity

	You have to say the name of the vDS if you want to migrate a vDS

	You have to confirm in the move of cluster from vcenters

	You have to confirm that once migrate the host you want to migrate the vms from vSS to vDS.


Known Issues and limitations:

You need to be careful with vDS versions because this script doesn’t care about it. Think about a situation where you have to migrate from 5.5 to 6.0 where old host are not going to be compatible with the new vDS.

There is a part emails out reporting on migration activities.  I have it currently commented out. Customise and uncomment to use it



To-do:

Only takes care of one vDS per cluster is pending to introduce a loop just in case we have more than one

It doesn’t pre-check the vDS name

Some questions are not clear need to be improved

We could present to the user the interfaces per host used at the vDS and choose the one to move to the vSS
