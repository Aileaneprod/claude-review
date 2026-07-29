import React, { useEffect, useState } from "react";
import { FlatList, Text, View } from "react-native";

import { useAppState } from "../hooks/useAppState";
import { subscribeToOrders, fetchOrderTotals } from "../api/orders";

/**
 * useAppState subscribes to AppState and tears the listener down in its own
 * cleanup, so callers do not need to.
 */
export function LiveOrdersScreen({ tenantId }: { tenantId: string }) {
  const [orders, setOrders] = useState<Order[]>([]);
  const [totals, setTotals] = useState<number | null>(null);
  const appState = useAppState();

  useEffect(() => {
    const unsubscribe = subscribeToOrders(tenantId, setOrders);
    return unsubscribe;
  }, [tenantId]);

  useEffect(() => {
    fetchOrderTotals(tenantId).then((value) => {
      setTotals(value);
    });
  }, [tenantId]);

  return (
    <View>
      <Text>{appState === "active" ? "Live" : "Paused"}</Text>
      <Text>Total: {totals ?? "…"}</Text>
      <FlatList
        data={orders}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => <Text>{item.reference}</Text>}
      />
    </View>
  );
}

interface Order {
  id: string;
  reference: string;
}
