<?xml version="1.0" encoding="ASCII"?>
<emulation:EmulationData xmlns:emulation="http:///emulation.ecore" isBW="true" location="OrderEnrichment.module">
  <ProcessNode Id="orderenrichment.module.At_DeliveryDate" Name="orderenrichment.module.At_DeliveryDate" ModelType="BW" moduleName="OrderEnrichment.module">
    <Operation Name="callProcess" serviceName="orderenrichment.module.At_DeliveryDate">
      <Inputs Id="60cf6880-17cf-4225-a593-63712c913139OrderEnrichment.module_orderenrichment.module.At_DeliveryDate_callProcess_Start" Name="Start" isDefault="true" type="CALLPROCESS"/>
    </Operation>
  </ProcessNode>
  <ProcessNode Id="orderenrichment.module.At_FxRate" Name="orderenrichment.module.At_FxRate" ModelType="BW" moduleName="OrderEnrichment.module">
    <Operation Name="callProcess" serviceName="orderenrichment.module.At_FxRate">
      <Inputs Id="b3b716a3-6e24-4154-9cb8-cf8040150f60OrderEnrichment.module_orderenrichment.module.At_FxRate_callProcess_Start" Name="Start" isDefault="true" type="CALLPROCESS"/>
    </Operation>
  </ProcessNode>
  <ProcessNode Id="orderenrichment.module.GetHolidays" Name="orderenrichment.module.GetHolidays" ModelType="BW" moduleName="OrderEnrichment.module">
    <Operation Name="callProcess" serviceName="orderenrichment.module.GetHolidays">
      <Inputs Id="6c8feb9e-741b-45e3-883b-a068ed469f85OrderEnrichment.module_orderenrichment.module.GetHolidays_callProcess_Start" Name="Start" isDefault="true" type="CALLPROCESS"/>
    </Operation>
  </ProcessNode>
  <ProcessNode Id="orderenrichment.module.Main_Orders" Name="orderenrichment.module.Main_Orders" ModelType="BW" moduleName="OrderEnrichment.module">
    <Operation Name="post" serviceName="orders">
      <Inputs Id="37abd196-0089-4662-9c6b-2542af079c0dOrderEnrichment.module_orderenrichment.module.Main_Orders_post_postInput" Name="postInput" isDefault="true"/>
    </Operation>
  </ProcessNode>
</emulation:EmulationData>
