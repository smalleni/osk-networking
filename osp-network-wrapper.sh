DRIVER[0]="iptables_hybrid"
DRIVER[1]="openvswitch"
RUN=1
HOSTS="hosts"
if [ -f "${HOSTS}" ]; then
        echo "${HOSTS} is a valid file";
    else
        echo "${HOSTS} is not a valid inventory file";
        exit 1
    fi
for firewall_driver in "${DRIVER[@]}"
do
        if [ $RUN == 1 ]; then
          ansible-playbook -i $HOSTS adjustment-firewall_driver.yml --extra-vars "driver=$firewall_driver"
          ./OSP-MutliNetwork-UPerf.sh $RUN $firewall_driver m1.small
          RUN=2
        else
          ansible-playbook -i $HOSTS adjustment-firewall_driver.yml --extra-vars "driver=$firewall_driver"
          ./OSP-MutliNetwork-UPerf.sh $RUN $firewall_driver m1.small
        fi
done
